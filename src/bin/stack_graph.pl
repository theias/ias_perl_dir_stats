#!/usr/bin/perl

# $Id: stack_graph.pl 8347 2017-12-07 16:56:54Z mvanwinkle $

=pod

=head1 NAME

stack_graph.pl - Creates stack graphs for file sizes going back in time

=head1 SYNOPSIS

  stack_graph.pl \
  	--label-files var_log \
  	/var/log/{apache2,apt,cups,dist-upgrade,iptraf}

This script needs to have read access on the files it's analyzing.

=head1 DESCRIPTION

It draws stack graphs of the summation of file sizes for the directories
that were specified over the command line "going back in time".

It answers the question: "If I wanted to keep all files up until X days,
how much space would be used?"

At any point on the graph, if you were to draw a vertical line then
the point where the graph intersects with that line is the amount of
space that would be required if you deleted all files that were older
than that date.

=head1 OPTIONS

=over 4

=item * [ --output-base-dir ] - the base directory for output.  The script creates a
(sensibly named?) directory under that for the results.

=item * [ --output-dir ] - Where the script should put its files.
Overrides the (sensible) defaults the script chooses for the output directory.

=item * [ --max-age ] - the maximum age (in seconds) of files to include in the calculations

=item * [ --exclude regex1 [ --exclude regex2 ] ] - a list of regular expressions to
to exclude when looking for files

=item * [ --label-files ] - a label that gets inserted in to the output file names

=item * [ --follow ] - follow symbolic links. This will cause the preprocess exclude
to not be enabled, but will allow you to do things like symbolically link
directories under one directory, and analyze their space usage as a whole.

=back

=head1 BUGS

There is quite an annoying "bug" in File::Find where symbolic links
can not be followed and preprocess doesn't get executed.

It's documented as:
	if follow or follow_fast are enabled
		then preprocess is a no-op
Which, apparently applies to "follow_skip=>2" as well; which is the
"ideal" behavior in this case.

This means that if you want to follow symbolic links, the exclude code
inside of preprocess won't get executed and directories, such as ".snapshot"
(if specified as an exclude) will be traversed BUT subsequently ignored as
the wanted subroutine contains code to exclude them.

=cut


use strict;
use warnings;

use Data::Dumper;
use DateTime;
use File::Find;
use File::Path;
use IO::File;
use Getopt::Long;
use Pod::Usage;

my (
	$output_base_dir,
	$output_dir,
	$MAX_AGE,
	@EXCLUDE,
	$label_files,
	$FOLLOW,
);

my $DEFAULT_OUTPUT_BASE_DIR = '/tmp/file_size_stack_graph';

GetOptions(
	"output-base-dir=s" => \$output_base_dir,
	"output-dir=s" => \$output_dir,
	"max-age=i" => \$MAX_AGE,
	"exclude=s@" => \@EXCLUDE,
	'label-files=s' => \$label_files,
	'follow' => \$FOLLOW,
)
or pod2usage(
	-message => "Invalid options specified.\n"
		. "Please perldoc this file for more information.",
	-exitval => 1
);

$FOLLOW = 0 if (! defined $FOLLOW);

$label_files ||= 'BLANK_LABEL';
$label_files = $$ . '-' . $label_files;

my $YYYY_MM_DD_HH_MM_SS = get_yyyy_mm_dd_hh_mm_ss();
my $DEFAULT_OUTPUT_SUB_DIR = "$YYYY_MM_DD_HH_MM_SS-$label_files";

# Globals... GERP.
my %DIRECTORY_SIZES;

my $TIME = time();

my $data = {};

my @output_path_components;

if (! defined $output_dir)
{
	push @output_path_components,
		$output_base_dir || $DEFAULT_OUTPUT_BASE_DIR;
	
	push @output_path_components,
		$DEFAULT_OUTPUT_SUB_DIR;
}
else
{
	if (! length($output_dir))
	{
		die "--output-dir was specified, but was empty";
	}
	push @output_path_components, $output_dir;
}

my $RUN_OUTPUT_DIR = join('/', @output_path_components);

File::Path::make_path($RUN_OUTPUT_DIR);

my $GNUPLOT_FILE_NAME = "plot-$label_files-$YYYY_MM_DD_HH_MM_SS.gnuplot";
my $GNUPLOT_DATA_FILE = "data-$label_files-$YYYY_MM_DD_HH_MM_SS.txt";
my $GNUPLOT_OUTPUT_FILE = "output-$label_files-$YYYY_MM_DD_HH_MM_SS.png";

if (! scalar @ARGV)
{
	print STDERR "No directories given...\n";
	exit 1;
}

my $directory;
foreach $directory(@ARGV)
{
	# print "Processing: $directory\n";
	next if ! -d $directory;
	$data->{$directory} = {};
	
	process_directory($directory, $data->{$directory});
}

transform_data_to_stack($data);

print "Run output dir: $RUN_OUTPUT_DIR",$/;
print "Gnuplot control file: ",$GNUPLOT_FILE_NAME,$/;
print "Gnuplot data file: ",$GNUPLOT_DATA_FILE,$/;
print "Gnuplot output file: ",$GNUPLOT_OUTPUT_FILE,$/;

exit;

sub transform_data_to_stack
{
	my ($data) = @_;
	
	my $gnuplot_output = q{};

	$gnuplot_output .= qq{
set xrange [] reverse
set xdata time
# set terminal png size 900, 300
set terminal png #enhanced truecolor
set output "$GNUPLOT_OUTPUT_FILE"
set style fill solid
set ylabel "Size in MB"
set timefmt "%Y-%m-%d"

set xtics rotate by 90 offset 0, -4
set bmargin 8

set grid
set multiplot
};

	my @directories = keys (%$data);

	#use Data::Dumper;
	#print "Directories", $/, Dumper(\@directories);

	my @plot_dashes;
	my $dir_count = scalar(@directories);
	
	# foreach $directory (sort keys %$data)
	my @directories_order = sort {$DIRECTORY_SIZES{$a} <=> $DIRECTORY_SIZES{$b} } keys %DIRECTORY_SIZES;
	foreach my $directory ( reverse @directories_order )
	{
		my @dir_numbers;
		
		my $count_dir_number;
		for $count_dir_number (reverse 1 .. $dir_count)
		{
			# print "Count dir number: $count_dir_number",$/;
			my $dir_number = $count_dir_number;
			my $using_string = sprintf('$%s', $dir_number+1);
			push @dir_numbers, $using_string;
			
		}
		
		$dir_count --;
		my $using_string = '(('.join('+',@dir_numbers).')/1e6)';
		
		my $size_display = sprintf(
			'%.2e bytes',
			$DIRECTORY_SIZES{$directory}
		);
		
		push @plot_dashes, qq{'$GNUPLOT_DATA_FILE' using 1:$using_string with filledcurves x1 title "$directory $size_display"};
	}
	
	my $transformed_data = {};
	if (! scalar @plot_dashes)
	{
		push @plot_dashes, 0;
	}
	
	$gnuplot_output .= "plot ".join(", \\\n",@plot_dashes) . qq{}.$/;

	my $gnuplot_output_file_name = join('/',
		$RUN_OUTPUT_DIR,
		$GNUPLOT_FILE_NAME,
	);

	my $fh = new IO::File ">$gnuplot_output_file_name"
		or die "Can't open $gnuplot_output_file_name for writing: $!";

	print $fh $gnuplot_output;

	$fh->close();

	my $directory;
	my $accumulator = {};
	
	foreach (@directories)
	{
		$accumulator->{$_} = 0;
	}
	
	my $date;
	
	foreach $directory (@directories_order)
	{
		foreach $date (keys %{$data->{$directory}})
		{
			$transformed_data->{$date}->{$directory} = $data->{$directory}->{$date};
		}
	}
	
	my $new_data = {};

	foreach $date (reverse sort keys %$transformed_data)
	{
		foreach $directory (@directories_order)
		{
			$accumulator->{$directory} += $transformed_data->{$date}->{$directory}
				if exists $transformed_data->{$date}->{$directory};
				
			$new_data->{$date}->{$directory} = $accumulator->{$directory};
		}	
	}
	
	my $data_output_file_name = join('/',
		$RUN_OUTPUT_DIR,
		$GNUPLOT_DATA_FILE,
	);
	
	my $data_output_fh = new IO::File ">$data_output_file_name"
		or die "Can't open $data_output_file_name for writing: $!";
		
	
	foreach $date (sort keys %$transformed_data)
	{
		my @columns;
		push @columns, $date;
		
		foreach $directory (@directories_order)
		{
			push @columns, $new_data->{$date}->{$directory};
		}
		print $data_output_fh join("\t", @columns),$/;
	}
	
	$data_output_fh->close();
}

sub preprocess_directory
{
	# print "Preprocess\n";
	my (@directories) = @_;
	if (! scalar(@EXCLUDE) )
	{
		return @directories;
	}
	my %wanted;
	@wanted{@directories} = (1) x scalar(@directories);
	my $exclude_me;
	my $directory;
	DIRECTORY: foreach $directory (@directories)
	{
		foreach $exclude_me (@EXCLUDE)
		{
			if ($directory =~ m/$exclude_me/)
			{
				delete $wanted{$directory};
			}
		}
	}
	# use Data::Dumper;
	# print Dumper(\@wanted);
	return keys %wanted;
}

sub wanted_directory
{
	# print "In wanted.\n";
	my $exclude_me;
	foreach $exclude_me (@EXCLUDE)
	{
		# print "Excluding: $exclude_me";
		return if $File::Find::name =~ m/$exclude_me/;
	}
	return if (
		! -f $File::Find::name
		&& ! -d $File::Find::name
	);
	my (
		$dev,
		$ino,
		$mode,
		$nlink,
		$uid,
		$gid,
		$rdev,
		$size,
		$atime,
		$mtime,
		$ctime,
		$blksize,
		$blocks,
	) = stat($File::Find::name);

	return if (
		$MAX_AGE
		&& $TIME - $mtime > $MAX_AGE
	);
	
	my $dt = DateTime->from_epoch(epoch => $mtime);
	$data->{$dt->ymd()}+=$size;
	$DIRECTORY_SIZES{$directory}+=$size;
}

sub process_directory
{
	my ($directory, $data) = @_;

	find(
		{
			preprocess => \&preprocess_directory,
						
			wanted => \&wanted_directory,
			follow => $FOLLOW,
			no_chdir => 1,
		},
		$directory,
	); 
}

sub get_yyyy_mm_dd_hh_mm_ss
{
	use POSIX qw(strftime);
	
	return strftime("%Y-%m-%d-%H-%M-%S", localtime);
	
}
