#!perl

# Copyright (c) 2002 Mattia Barbon.
# Copyright (c) 2002 Audrey Tang.
# This package is free software; you can redistribute it and/or
# modify it under the same terms as Perl itself.

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use File::Basename;
use File::Glob;
use File::Spec::Functions ':ALL';
use Cwd 'abs_path';
use Getopt::Long;
use IO::Compress::Gzip qw(gzip $GzipError);
use DynaLoader;
use Config;

my $chunk_size = 32768;
my $compress = 0;

GetOptions(
    "c|chunk-size=i"    => \$chunk_size,
    "z|compress"        => \$compress)
    && @ARGV >= 1
        or die "Usage: $0 [-c CHUNK][-z] par fallback_embedded_file... > file.c\n";
my ($par, @fallback_embedded_files) = @ARGV;

sub is_system_lib;

my $dlls;
for ($^O)
{
    # sane platforms: use "ldd"
    if (/linux|solaris|freebsd|openbsd|cygwin/i) 
    {
        print STDERR qq[# using "ldd" to find shared libraries needed by $par\n];
        if ($^O =~ /cygwin/i)
        {
            chomp(my $system_root = qx( cygpath --unix '$ENV{SYSTEMROOT}' ));
            print STDERR "### SystemRoot (as Unix path) = $system_root\n";
            *is_system_lib = sub { shift =~ m{^/usr/bin/(?!cygcrypt\b)|^\Q$system_root\E/}i }; 
            # NOTE: cygcrypt-0.dll is not (anymore) in the set of default Cygwin packages
        }
        else
        {
            *is_system_lib = sub { shift =~ m{^(?:/usr)?/lib(?:32|64)?/} };
        }

        $dlls = ldd($par); 

        # weed out system libs (but exclude the shared perl lib)
        while  (my ($name, $path) = each %$dlls)
        {
            delete $dlls->{$name} if is_system_lib($path) && $name !~ /perl/;
        }
        last;
    }

    # Max OS X: use "otool -L" if available
    if (/darwin/i && (qx(otool -h $par), $? == 0)) 
    {
        print STDERR qq[# using "otool -L" to find shared libraries needed by $par\n];
        *is_system_lib = sub { shift =~ m{^/usr/lib|^/System/Library/} };

        $dlls = otool($par); 

        # weed out system libs (but exclude the shared perl lib)
        while  (my ($name, $path) = each %$dlls)
        {
            delete $dlls->{$name} if is_system_lib($path) && basename($path) !~ /perl/;
        }
        last;
    }

    # Windows with Mingw toolchain: use "objdump" recursively
    if (/mswin32/i && (qx(objdump --version), $? == 0))
    {
        print STDERR qq[# using "objdump" recusrively to find DLLs needed by $par\n];
        my $system_root = abs_path($ENV{SystemRoot});
        *is_system_lib = sub { abs_path(shift) =~ m{^\Q$system_root\E/}i };

        $dlls = objdump_win32($par, dirname($^X));
        last;
    }

    # fall back to guessing game
    print STDERR qq[# fall back to guessing what DLLs are needed by $par\n];
    $dlls = { map { basename($_) => $_ } @fallback_embedded_files };
}


# par is always the first embedded file
my @embedded_files;
embed(\@embedded_files, basename($par), $par);

while (my ($name, $file) = each %$dlls)
{
    embed(\@embedded_files, $name, $file);
}

print "static embedded_file_t embedded_files[] = {\n";
print "  { \"$_->{name}\", $_->{size}, $_->{chunks} },\n" foreach @embedded_files;
print "  { NULL, 0, NULL }\n};";
           
exit 0;


sub embed
{
    my ($embedded, $name, $file) = @_;
    print STDERR qq[# embedding "$file" as "$name"\n];

    my $n = @$embedded;
    push @$embedded, 
    { 
        name   => $name, 
        size   => -s $file, 
        chunks => file2c("file$n", $file) 
    };
}

sub ldd
{
    my ($file) = @_;

    my $out = qx(ldd $file);
    die qq["ldd $file" failed\n] unless $? == 0;

    # NOTE: On older Linux/glibc (e.g. seen on Linux 3.2.0/glibc 2.13)
    # ldd prints a line like
    #    linux-vdso.so.1 =>  (0x00007fffd2ff2000)
    # (without a pathname between "=>" and the address)
    # while newer versions omit "=>" in this case.
    my %dlls = $out =~ /^ \s* (\S+) \s* => \s* ( \/ \S+ ) /gmx;

    while (my ($name, $path) = each %dlls)
    {
        unless (-r $path)
        {
            warn qq[# ldd reported strange path: $path\n];
            delete $dlls{$name};
            next;
        }
    }

    return \%dlls;
}

# NOTE: "otool -L" is NOT recursive, i.e. it's the equivalent
# of "objdump -ax" or "readelf -d" on Linux, but NOT "ldd".
# So perhaps a recursive method like the one for objdump below is in order.
sub otool
{
    my ($file) = @_;

    my $out = qx(otool -L $file);
    die qq["otool -L $file" failed\n] unless $? == 0;

    return { map { basename($_) => $_ } $out =~ /^ \s+ (\S+) /gmx };
}

sub objdump_win32
{
    my ($path, @search_first_in) = @_;

    # NOTE: Looks like Perl on Windows (e.g. Strawberry) doesn't set 
    # $Config{ldlibpthname} - one could argue that its value should be "PATH".
    # But even where it is defined (e.g. "LD_LIBRARY_PATH" on Linux)
    # DynaLoader *appends* (an appropriately split)
    # $ENV{$Config{ldlibpthname}} to its search path, @dl_library_path, 
    # which is wrong in our context as we want it to be searched first.
    # Hence, provide our own value for @dl_library_path.
    local @DynaLoader::dl_library_path = (@search_first_in, path());

    my %dlls;
    my %seen;
    my $walker;
    $walker = sub 
    {
        my ($obj) = @_;
        return if $seen{lc $obj}++;

        my $out = qx(objdump -ax "$obj");
        die "objdump failed: $!\n" unless $? == 0;

        foreach my $dll ($out =~ /^\s*DLL Name:\s*(\S+)/gm)
        {
            next if $dlls{lc $dll};             # already found

            my ($file) = DynaLoader::dl_findfile($dll) or next;
            $dlls{lc $dll} = $file;

            next if is_system_lib($file);       # no need to recurse on a system library
            $walker->($file);                   # recurse
        }
    };
    $walker->(abs_path($path));

    # weed out system libraries
    while (my ($name, $path) = each %dlls)
    {
        delete $dlls{$name} if is_system_lib($path);
    }
        
    return \%dlls;
}

sub file2c
{
    my ($prefix, $path) = @_;

    my $bin = do           # a scalar reference
    {
        open my $in, "<", $path or die "open input file '$path': $!";
        binmode $in;
        local $/ = undef;
        my $slurp = <$in>;
        close $in;
        \$slurp;
    };


    if ($compress)
    {
        my $gzipped;
        my $status = gzip($bin, \$gzipped)
            or die "gzip failed: $GzipError\n";
        $bin = \$gzipped;
    }

    my $len = length $$bin;
    my $chunk_count = int(( $len + $chunk_size - 1 ) / $chunk_size);

    my @chunks;
    for (my $offset = 0, my $i = 0; $offset <= $len; $offset += $chunk_size, $i++)
    {
        my $name = "${prefix}_${i}";
        push @chunks, { 
               name => $name,
               len  => print_chunk(substr($$bin, $offset, $chunk_size), $name),
        };
    } 

    print "static chunk_t ${prefix}[] = {\n";
    print "  { $_->{len}, $_->{name} },\n" foreach @chunks;
    print "  { 0, NULL } };\n\n";

    return $prefix;
}

sub print_chunk 
{
    my ($chunk, $name) = @_;

    my $len = length($chunk);
    print qq[static unsigned char ${name}[] =];
    my $i = 0;
    do
    {
        print qq[\n"];
        while ($i < $len)
        {
            printf "\\x%02x", ord(substr($chunk, $i++, 1));
            last if $i % 16 == 0;
        }
        print qq["];
    } while ($i < $len);
    print ";\n";
    return $len;
}

# local variables:
# mode: cperl
# end:
