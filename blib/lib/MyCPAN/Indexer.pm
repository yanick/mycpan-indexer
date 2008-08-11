#!/usr/bin/perl

package MyCPAN::Indexer;
use strict;

use warnings;
no warnings;

use subs qw(get_caller_info);
use vars qw($VERSION);

$VERSION = '0.10_02';

=head1 NAME

MyCPAN::Indexer - Index a Perl distribution

=head1 SYNOPSIS

	use MyCPAN::Indexer;

=head1 DESCRIPTION

=cut

use Carp qw(croak);
use Cwd;
use Data::Dumper;
use File::Basename;
use MD5;
use File::Path;
use Log::Log4perl qw(:easy);

use Distribution::Guess::BuildSystem;
use Module::Extract::Namespaces;
use Module::Extract::Version;


__PACKAGE__->run( @ARGV ) unless caller;

=over 4

=item run


=cut

sub run
	{
	my $class = shift;

	my $self = bless { dist_info => {} }, $class;

	$self->setup_run_info;

	DIST: foreach my $dist ( @_ )
		{
		DEBUG( "Dist is $dist\n" );

		unless( -e $dist )
			{
			ERROR( "Could not find [$dist]" );
			next;
			}

		INFO( "Processing $dist\n" );

		$self->clear_dist_info;
		$self->setup_dist_info( $dist ) or next DIST;

		$self->examine_dist or next DIST;

		$self->set_run_info( 'completed', 1 );
		$self->set_run_info( 'run_end_time', time );

		INFO( "Finished processing $dist\n" );
		DEBUG( sub { Dumper( $self ) } );
		}

	$self;
	}

=item examine_dist

Given a distribution, unpack it, look at it, and report the findings.
It does everything except the looking right now, so it merely croaks.
Most of this needs to move out of run and into this method.

=cut

{
my @methods = (
	#    method                error message                  fatal
	[ 'unpack_dist',        "Could not unpack distribtion!",     1 ],
	[ 'find_dist_dir',      "Did not find distro directory!",    1 ],
	[ 'get_file_list',      'Could not get file list',           1 ],
	[ 'parse_meta_files',   "Could not parse META.yml!",         0 ],
	[ 'find_modules',       "Could not find modules!",           1 ],
	);

sub examine_dist
	{
	my $self = shift;

	foreach my $tuple ( @methods )
		{
		my( $method, $error, $die_on_error ) = @$tuple;

		unless( $self->$method() )
			{
			ERROR( $error );
			if( $die_on_error ) # only if failure is fatal
				{
				ERROR( "Stopping: $error" );
				$self->set_run_info( 'fatal_error', $error );
				return;
				}
			}
		}

	my @file_info = ();
	foreach my $file ( @{ $self->dist_info( 'modules' ) } )
		{
		DEBUG( "Processing module $file\n" );
		my $hash = $self->get_module_info( $file );
		push @file_info, $hash;
		}

	$self->set_dist_info( 'file_info', [ @file_info ] );

	return 1;
	}
}

=item clear_run_info

Clear anything recorded about the run.

=cut

sub clear_run_info
	{
	DEBUG( "Clearing run_info\n" );
	$_[0]->{run_info} = {};
	}

=item setup_run_info( DISTPATH )

Given a distribution path, record various data about it, such as its size,
mtime, and so on.

Sets these items in dist_info:
	dist_file
	dist_size
	dist_basename
	dist_basename
	dist_author

=cut

sub setup_run_info
	{
	$_[0]->set_run_info( 'root_working_dir', cwd()   );
	$_[0]->set_run_info( 'run_start_time',   time    );
	$_[0]->set_run_info( 'completed',        0       );
	$_[0]->set_run_info( 'pid',              $$      );
	$_[0]->set_run_info( 'ppid',             getppid );

	return 1;
	}

=item set_run_info( KEY, VALUE )

Set something to record about the run. This should only be information
specific to the run. See C<set_dist_info> to record dist info.

=cut

sub set_run_info
	{
	my( $self, $key, $value ) = @_;

	DEBUG( "Setting run_info key [$key] to [$value]\n" );
	$self->{run_info}{$key} = $value;
	}

=item run_info( KEY )

Fetch some run info.

=cut

sub run_info
	{
	my( $self, $key ) = @_;

	DEBUG( "Run info for $key is " . $self->{run_info}{$key} );
	$self->{run_info}{$key};
	}

=item clear_dist_info

Clear anything recorded about the distribution.

=cut

sub clear_dist_info
	{
	DEBUG( "Clearing dist_info\n" );
	$_[0]->{dist_info} = {};
	}

=item setup_dist_info( DISTPATH )

Given a distribution path, record various data about it, such as its size,
mtime, and so on.

Sets these items in dist_info:
	dist_file
	dist_size
	dist_basename
	dist_basename
	dist_author

=cut

sub setup_dist_info
	{
	my( $self, $dist ) = @_;

	DEBUG( "Setting dist [$dist]\n" );
	$self->set_dist_info( 'dist_file',     $dist            );
	$self->set_dist_info( 'dist_size',     -s $dist         );
	$self->set_dist_info( 'dist_basename', basename($dist)  );
	$self->set_dist_info( 'dist_date',    (stat($dist))[9]  );
	DEBUG( "dist size " . $self->dist_info( 'dist_size' ) .
		" dist date " . $self->dist_info( 'dist_date' )
		);

	my( undef, undef, $author ) = $dist =~ m|/([A-Z])/\1([A-Z])/(\1\2[A-Z]+)/|;
	$self->set_dist_info( 'dist_author', $author );
	DEBUG( "dist author [$author]" );

	unless( $self->dist_info( 'dist_size' ) )
		{
		ERROR( "Dist size was 0!" );
		$self->set_run_info( 'fatal_error', "Dist size was 0!" );
		return;
		}
		
	return 1;
	}

=item set_dist_info( KEY, VALUE )

Set something to record about the distribution. This should only be information
specific to the distribution. See C<set_run_info> to record run info.

=cut

sub set_dist_info
	{
	my( $self, $key, $value ) = @_;

	DEBUG( "Setting dist_info key [$key] to [$value]\n" );
	$self->{dist_info}{$key} = $value;
	}

=item dist_info( KEY )

Fetch some distribution info.

=cut

sub dist_info
	{
	TRACE( sub { get_caller_info } );

	my( $self, $key ) = @_;

	#print STDERR Dumper( $self );
	DEBUG( "dist info for $key is " . $self->{dist_info}{$key} );
	$self->{dist_info}{$key};
	}

=item unpack_dist( DISTPATH )

Given a distribution path, this determines the archive type,
unpacks it into a temporary directory, and records what it
did.

Sets these items in run_info:

Sets these items in dist_info:
	dist_archive_type
	dist_extract_path
	
=cut

sub unpack_dist
	{
	TRACE( sub { get_caller_info } );

	require Archive::Extract;

	my $self = shift;
	my $dist = $self->dist_info( 'dist_file' );
	DEBUG( "Unpacking dist $dist" );
	
	return unless $self->get_unpack_dir;

	my $extractor = eval {
		Archive::Extract->new( archive => $dist )
		};
		
	if( $extractor->type eq 'gz' )
		{
		ERROR( "Dist claims to be a gz, so try .tgz instead" );
	
		$extractor = eval {
			Archive::Extract->new( archive => $dist, type => 'tgz' )
			};
		}

	unless( $extractor )
		{
		ERROR( "Still could not unpack $dist [$@]" );
		$self->set_dist_info( 'dist_archive_type', 'unknown' );
		return;	
		}
		
	$self->set_dist_info( 'dist_archive_type', $extractor->type );

	my $rc = $extractor->extract( to => $self->dist_info( 'unpack_dir' ) );

	DEBUG( "Archive::Extract returns [$rc]" );
	return unless( $rc );

	$self->set_dist_info( 'dist_extract_path', $extractor->extract_path );

	1;
	}

=item get_unpack_dir

Get a directory where you can unpack the archive. 

Sets these items in dist_info:
	unpack_dir

=cut

sub get_unpack_dir
	{
	TRACE( sub { get_caller_info } );

	require File::Temp;
	
	my $self = shift;

	( my $prefix = __PACKAGE__ ) =~ s/::/-/g;

	DEBUG( "Preparing temp dir in pid [$$]\n" );
	my $unpack_dir = eval { File::Temp::tempdir(
		$prefix . "-$$.XXXX",
		DIR     => $self->run_info( 'root_working_dir' ),
		CLEANUP => 1,
		) };

	if( $@ )
		{
		DEBUG( "Temp dir error for pid [$$] [$@]" );
		return;
		}
	
	$self->set_dist_info( 'unpack_dir', $unpack_dir );


	DEBUG( "Unpacking into directory [$unpack_dir]" );

	1;
	}
	
=item find_dist_dir

Looks at dist_info's unpack_dir and guesses where the module distribution
is. This accounts for odd archiving people may have used, like putting all
the good stuff in a subdirectory.

Sets these items in dist_info:
	dist_dir

=cut

sub find_dist_dir
	{
	TRACE( sub { get_caller_info } );

	DEBUG( "Cwd is " . $_[0]->dist_info( "unpack_dir" ) );

	my @files = qw( MANIFEST Makefile.PL Build.PL META.yml );
	
	if( grep { -e } @files )
		{
		$_[0]->set_dist_info( $_[0]->dist_info( "unpack_dir" ) );
		return 1;
		}

	require File::Find::Closures;
	require File::Find;

	DEBUG( "Did not find dist directory at top level" );
	my( $wanted, $reporter ) = 
		File::Find::Closures::find_by_directory_contains( @files );

	File::Find::find( $wanted, $_[0]->dist_info( "unpack_dir" ) );

	my @found = $reporter->();
	DEBUG( "Found files @found" );
	
	my( $first ) = $reporter->();
	DEBUG( "Found dist file at $first" );
	print "Waiting for STDIN..."; <STDIN>;
	unless( $first )
		{
		DEBUG( "Didn't find anything that looks like a module directory!" );
		return;
		}

	if( chdir $first )
		{
		DEBUG "Changed to $first";
		$_[0]->set_dist_info( 'dist_dir', $first );
		return 1;
		}
	exit;
	return;
	}

=item get_file_list

Returns as an array reference the list of files in MANIFEST.

Sets these items in dist_info:
	manifest

=cut

sub get_file_list
	{
	TRACE( sub { get_caller_info } );
	DEBUG( "Cwd is " . cwd() );
	
	unless( -e 'Makefile.PL' or -e 'Build.PL' )
		{
		ERROR( "No Makefile.PL or Build.PL" );
		$_[0]->set_dist_info( 'manifest', [] );

		return;
		}

	require ExtUtils::Manifest;

	my $manifest = [ sort keys %{ ExtUtils::Manifest::manifind() } ];

	$_[0]->set_dist_info( 'manifest', $manifest );

	$manifest;
	}

=item get_blib_file_list

Returns as an array reference the list of files in blib. You need to call
something like C<run_build_file> first.

Sets these items in dist_info:
	blib

=cut

sub get_blib_file_list
	{
	TRACE( sub { get_caller_info } );

	unless( -d 'blib/lib' )
		{
		ERROR( "No blib/lib found!" );
		$_[0]->set_dist_info( 'blib', [] );

		return;
		}

	require ExtUtils::Manifest;

	my $blib = [ grep { m|^blib/| and ! m|.exists$| }
		sort keys %{ ExtUtils::Manifest::manifind() } ];

	$_[0]->set_dist_info( 'blib', $blib );
	}

=item look_in_lib

=cut

sub look_in_lib
	{
	TRACE( sub { get_caller_info } );

	require File::Find::Closures;
	require File::Find;
	
	my( $wanted, $reporter ) = File::Find::Closures::find_by_regex( qr/\.pm\z/ );
	File::Find::find( $wanted, 'lib' );
	
	my @modules = $reporter->();
	unless( @modules )
		{
		DEBUG( "Did not find any modules in lib" );
		return;
		}
	
	$_[0]->set_dist_info( 'modules', [ @modules ] );
	
	return 1;
	}
	
=item look_in_cwd

=cut

sub look_in_cwd
	{
	TRACE( sub { get_caller_info } );
	
	my @modules = glob( "*.pm" );

	unless( @modules )
		{
		DEBUG( "Did not find any modules in cwd" );
		return;
		}

	$_[0]->set_dist_info( 'modules', [ @modules ] );
	
	return 1;
	}
	
=item parse_meta_files

Parses the META.yml and returns the YAML object.

Sets these items in dist_info:
	META.yml

=cut

sub parse_meta_files
	{
	TRACE( sub { get_caller_info } );

	if( -e 'META.yml'  )
		{
		require YAML::Syck;
		my $yaml = YAML::Syck::LoadFile( 'META.yml' );
		$_[0]->set_dist_info( 'META.yml', $yaml );
		return $yaml;
		}

	return;
	}

=item find_modules

=cut

sub find_modules
	{
	TRACE( sub { get_caller_info } );

	my @methods = (
		[ 'run_build_file', "Got from running build file"  ],
		[ 'look_in_lib',    "Guessed from looking in lib/" ],
		[ 'look_in_cwd',    "Guessed from looking in cwd"  ],
	);
	
	foreach my $tuple ( @methods )
		{
		my( $method, $message ) = @$tuple;
		next unless $_[0]->$method();
		DEBUG( $message );
		return 1;
		}
		
	return;
	}
	
=item run_build_file

This method is one stop shopping for calls to C<choose_build_file>,
C<setup_build>, C<run_build>.

=cut

sub run_build_file
	{
	TRACE( sub { get_caller_info } );

	foreach my $method ( qw( 
		choose_build_file setup_build run_build get_blib_file_list ) )
		{
		$_[0]->$method() or return;
		}
		
	my @modules = grep /\.pm$/, @{ $_[0]->dist_info( 'blib' ) };
	DEBUG( "Modules are @modules\n" );

	$_[0]->set_dist_info( 'modules', [ @modules ] );
	
	return 1;
	}

=item choose_build_file

Guess what the build file for the distribution is, using C<Distribution::Guess::BuildSystem>.

Sets these items in dist_info:
	build_file

=cut

sub choose_build_file
	{
	TRACE( sub { get_caller_info } );

	require Distribution::Guess::BuildSystem;
	my $guesser = Distribution::Guess::BuildSystem->new(
		dist_dir => $_[0]->dist_info( 'dist_dir' )
		);

	$_[0]->set_dist_info(
		'build_system_guess',
		$guesser->just_give_me_a_hash
		);

	my $file = eval { $guesser->preferred_build_file };
	DEBUG( "Build file is $file" );
	DEBUG( "At is $@" ) if $@;
	unless( defined $file )
		{
		ERROR( "Did not find a build file" );
		return;
		}

	$_[0]->set_dist_info( 'build_file', $file );

	return 1;
	}

=item setup_build

Runs the build setup file (Build.PL, Makefile.PL) to prepare for the
build. You need to run C<choose_build_file> first.

Sets these items in dist_info:
	build_file_output

=cut

sub setup_build
	{
	TRACE( sub { get_caller_info } );

	my $file = $_[0]->dist_info( 'build_file' );

	my $command = "$^X $file";

	$_[0]->run_something( $command, 'build_file_output' );
	}

=item run_build

Run the build file (Build.PL, Makefile). Run C<setup_build> first.

Sets these items in dist_info:
	build_output

=cut

sub run_build
	{
	TRACE( sub { get_caller_info } );

	my $file = $_[0]->dist_info( 'build_file' );

	my $command = $file eq 'Build.PL' ? "$^X ./Build" : "make";

	$_[0]->run_something( $command, 'build_output' );
	}

=item run_something( COMMAND, KEY )

Run the shell command and record the output in the dist_info for KEY. This
merges the outputs into stdout and closes stdin by redirecting /dev/null into
COMMAND.

=cut

sub run_something
	{
	my $self = shift;
	my( $command, $info_key ) = @_;

	{
	require IPC::Open2;
	DEBUG( "Running $command" );
	my $pid = IPC::Open2::open2(
		my $read,
		my $write,
		"$command 2>&1 < /dev/null"
		);

	close $write;

	{
	local $/;
	my $output = <$read>;
	$self->set_dist_info( $info_key, $output );
	}

	waitpid $pid, 0;
	}

	}

=item get_module_info


=cut

sub get_module_info
	{
	my( $self, $file ) = @_;
	DEBUG( "get_module_info called with [$file]\n" );

	# get file name as key
	my $hash = { name => $file };

	# file digest
	{
	my $context = MD5->new;
	$context->add( $file );
	$hash->{md5} = $context->hexdigest;
	}

	# mtime
	$hash->{mtime} = ( stat $file )[9];

	# file size
	$hash->{bytesize} = -s _;

	# version
	$hash->{version} = Module::Extract::VERSION->parse_version_safely( $file );

	# packages
	my @packages      = Module::Extract::Namespaces->from_file( $file );
	my $first_package = Module::Extract::Namespaces->from_file( $file );

	$hash->{packages} = [ @packages ];

	$hash->{primary_package} = $first_package;

	$hash;
	}

=item cleanup

Removes the unpack_dir.

=cut

sub cleanup
	{
	return 1;

	File::Path::rmtree(
		[
		$_[0]->run_info( 'unpack_dir' )
		],
		0, 0
		);

	return 1;
	}

=item report_dist_info

Write a nice report. This isn't anything useful yet. From your program,
take the object and dump it in some way.

=cut

sub report_dist_info
	{
	no warnings 'uninitialized';

	#print $self->dist_info( 'dist' ), "\n\t";

	my $module_hash = $_[0]->dist_info( 'module_versions' );

	while( my( $k, $v ) = each %$module_hash )
		{
		print "$k => $v\n\t";
		}

	print "\n";
	}

=item get_caller_info

=cut

sub get_caller_info
	{
	require File::Basename;
	
	my(
		$package, $filename, $line, $subroutine, $hasargs,
		$wantarray, $evaltext, $is_require, $hints, $bitmask
		) = caller(4);
	
	$filename = File::Basename::basename( $filename );
	
	return join " : ", $package, $filename, $line, $subroutine;
	}
	
=back

=head1 TO DO

=over 4

=item If build fails, have a fallback method to find the modules

=back

=head1 SEE ALSO


=head1 SOURCE AVAILABILITY

This source is part of a SourceForge project which always has the
latest sources in CVS, as well as all of the previous releases.

	http://sourceforge.net/projects/brian-d-foy/

If, for some reason, I disappear from the world, one of the other
members of the project can shepherd this module appropriately.

=head1 AUTHOR

brian d foy, C<< <bdfoy@cpan.org> >>

=head1 COPYRIGHT AND LICENSE

Copyright (c) 2008, brian d foy, All Rights Reserved.

You may redistribute this under the same terms as Perl itself.

=cut

1;
