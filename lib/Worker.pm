package MyCPAN::Indexer::Worker;
use strict;
use warnings;

use base qw(MyCPAN::Indexer::Component);
use vars qw($VERSION $logger);
$VERSION = '1.28_10';

use Cwd;
use File::Basename;
use File::Spec::Functions qw(catfile);
use Log::Log4perl;
use MyCPAN::Indexer;
use Proc::ProcessTable;
use YAML;

=head1 NAME

MyCPAN::Indexer::Worker - Do the indexing

=head1 SYNOPSIS

Use this in backpan_indexer.pl by specifying it as the queue class:

	# in backpan_indexer.config
	worker_class  MyCPAN::Indexer::Worker

=head1 DESCRIPTION

This class takes a distribution and analyses it. This is what the dispatcher
hands a disribution to for the actual indexing.

=head2 Methods

=over 4

=item get_task

C<get_task> sets the C<child_task> key in the notes. The
value is a code reference that takes a distribution path as its only
argument and indexes that distribution.

See L<MyCPAN::Indexer::Tutorial> for details about what C<get_task> expects
and should do.

=cut

BEGIN {
	$logger = Log::Log4perl->get_logger( 'Worker' );
	}

sub component_type { $_[0]->worker_type }

sub get_task
	{
	my( $self ) = @_;

	my $config  = $self->get_config;

	my $coordinator = $self->get_coordinator;
	
	my $Indexer = $config->indexer_class || 'MyCPAN::Indexer';

	$logger->debug( "Worker class is " . __PACKAGE__ );
	$logger->debug( "Indexer class is $Indexer" );

	my $child_task = sub {
		my $dist = shift;

		my $dist_basename = basename( $dist );
		
		my $basename = $coordinator->get_reporter->check_for_previous_successful_result( $dist );
		$logger->debug( "Found successful report for $dist_basename" ) unless $basename;
		return bless { 
			dist_info => {
				dist_path     => $dist,
				dist_basename => $dist_basename
				},
			skipped => 1, 
			}, $Indexer unless $basename;

		my $error = $coordinator->get_reporter->check_for_previous_error_result( $dist );
		$logger->debug( "Error report returned $error" );
		$logger->debug( "Found error report for $dist_basename" ) if $error;
		return bless {
			dist_info => {
				dist_path    => $dist,
                                dist_basename => $dist_basename,
                                },
                        skip_error => 1,
                        }, $Indexer if $error;

		$logger->info( "Starting Worker for $dist_basename\n" );

		eval "require $Indexer" or die;

		my $starting_dir = cwd();

		unless( chdir $config->temp_dir )
			{
			$logger->error( "Could not change to " . $config->temp_dir . " : $!\n" );
			exit 255;
			}

		$logger->debug( sprintf "Setting alarm for %d seconds", $config->alarm );
		local $SIG{ALRM} = sub {
			kill 9,
				map  { $_->{pid} }
				grep { $_->{'ppid'} == $$ }
				@{ Proc::ProcessTable->new->table }; 
	
			die "Alarm rang for $dist_basename!\n";
			};

		local $SIG{CHLD} = 'IGNORE';
		alarm( $config->alarm || 15 );
		$logger->debug( "Examining $dist_basename" );
		my $info = eval { $Indexer->run( $dist ) };
		$logger->debug( "Done examining $dist_basename" );
		my $at = $@; chomp $at;
		alarm 0;

		chdir $starting_dir;

		unless( defined $info )
			{
			$logger->error( "Indexing failed for $dist_basename: $at" );
			$info = bless {}, $Indexer; # XXX TODO make this a real class
			$info->setup_dist_info( $dist );
			$info->setup_run_info;
			$info->set_run_info( qw(completed 0) );
			$info->set_run_info( error => $@ );
			}
		elsif( ! eval { $info->run_info( 'completed' ) } )
			{
			$logger->error( "Indexing for $dist_basename did not complete" );
			$self->_copy_bad_dist( $info ) if $config->copy_bad_dists;
			}

		$self->_add_run_info( $info );
		
		$coordinator->get_note('reporter')->( $info );

		$logger->debug( "Worker for $dist_basename done" );

		$info;
		};

	$coordinator->set_note( 'child_task', $child_task );
	
	1;
	}

sub _copy_bad_dist
	{
	my( $self, $info ) = @_;

	my $config  = $self->get_config;
	
	if( my $bad_dist_dir = $config->copy_bad_dists )
		{
		my $dist_file = $info->dist_info( 'dist_file' );
		my $basename  = $info->dist_info( 'dist_basename' );
		my $new_name  = catfile( $bad_dist_dir, $basename );

		unless( -e $new_name )
			{
			$logger->debug( "Copying bad dist" );

			my( $in, $out );

			unless( open $in, "<", $dist_file )
				{
				$logger->fatal( "Could not open bad dist to $dist_file: $!" );
				return;
				}

			unless( open $out, ">", $new_name )
				{
				$logger->fatal( "Could not copy bad dist to $new_name: $!" );
				return;
				}

			while( <$in> ) { print { $out } $_ }
			close $in;
			close $out;
			
			}
		}
	}

sub _add_run_info
	{
	my( $self, $info ) = @_;

	my $config = $self->get_config;

	return unless eval { $info->can( 'set_run_info' ) };

	$info->set_run_info( $_, $config->get( $_ ) )
		foreach ( $config->directives );

	$info->set_run_info( 'uuid', $self->get_note( 'UUID' ) );

	$info->set_run_info( 'child_pid',  $$ );
	$info->set_run_info( 'parent_pid', eval { $config->indexer_class->getppid } );

	$info->set_run_info( 'ENV', \%ENV );

	return 1;
	}

=back


=head1 SEE ALSO

MyCPAN::Indexer, MyCPAN::Indexer::Tutorial

=head1 SOURCE AVAILABILITY

This code is in Github:

	git://github.com/briandfoy/mycpan-indexer.git

=head1 AUTHOR

brian d foy, C<< <bdfoy@cpan.org> >>

=head1 COPYRIGHT AND LICENSE

Copyright (c) 2008-2010, brian d foy, All Rights Reserved.

You may redistribute this under the same terms as Perl itself.

=cut

1;
