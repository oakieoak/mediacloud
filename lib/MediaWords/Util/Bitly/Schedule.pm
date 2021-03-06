package MediaWords::Util::Bitly::Schedule;

#
# Bit.ly processing schedule helper
#

use strict;
use warnings;

use Modern::Perl "2015";
use MediaWords::CommonLibs;

use MediaWords::Job::Bitly::FetchStoryStats;
use MediaWords::Util::Bitly;
use MediaWords::Util::DateTime;
use MediaWords::Util::Config;
use MediaWords::Util::SQL;
use Readonly;
use DateTime;

# Don't fetch data for stories older than this date
sub _story_timestamp_lower_bound()
{
    return DateTime->new( year => 2008, month => 01, day => 01 )->epoch;
}

# Don't fetch data for stories newer than this date
sub _story_timestamp_upper_bound()
{
    return DateTime->now()->epoch;
}

# return true if feeds.skip_bitly_processing is set for any the story's feeds
sub _skip_processing_for_story_feed
{
    my ( $db, $stories_id ) = @_;

    my $skip = $db->query( <<SQL, $stories_id )->hash;
select 1
    from feeds_stories_map fsm
        join feeds f on ( f.feeds_id = fsm.feeds_id )
    where
        fsm.stories_id = \$1 and
        f.skip_bitly_processing = true
    limit 1
SQL

    return $skip ? 1 : 0;
}

sub _story_timestamp($)
{
    my $story = shift;

    my $stories_id = $story->{ stories_id };

    my $publish_date = $story->{ publish_date };
    unless ( $publish_date )
    {
        LOGCONFESS "Publish date is unset for story $stories_id: " . Dumper( $story );
    }

    my $story_timestamp = MediaWords::Util::SQL::get_epoch_from_sql_date( $publish_date );
    if ( $story_timestamp <= _story_timestamp_lower_bound() or $story_timestamp >= _story_timestamp_upper_bound() )
    {
        DEBUG "Publish timestamp is lower than lower bound for story $stories_id, using collect_date";

        my $collect_date = $story->{ collect_date };
        unless ( $collect_date )
        {
            die "Collect date is unset for story $stories_id";
        }

        $story_timestamp = MediaWords::Util::SQL::get_epoch_from_sql_date( $collect_date );
    }

    return $story_timestamp;
}

sub _story_start_timestamp($)
{
    my $story_timestamp = shift;

    # Span -2 days to the past (to account for TZ conversion errors)
    return $story_timestamp - ( 60 * 60 * 24 * 2 );
}

sub _story_end_timestamp($)
{
    my $story_timestamp = shift;

    # 30 days to the future
    my $end_timestamp = $story_timestamp + ( 60 * 60 * 24 * 30 );
    if ( $end_timestamp > _story_timestamp_upper_bound() )
    {
        DEBUG(
            sub {
                "End timestamp is in the future, so truncating to current timestamp; " .
                  "consider fetching Bit.ly stats after a longer delay";
            }
        );
        $end_timestamp = DateTime->now()->epoch;
    }

    return $end_timestamp;
}

sub story_processing_is_enabled()
{
    unless ( MediaWords::Util::Bitly::bitly_processing_is_enabled() )
    {
        DEBUG( "Bit.ly story processing is not enabled because Bit.ly processing itself is not enabled." );
        return 0;
    }

    my $config = MediaWords::Util::Config::get_config();
    my $enabled = $config->{ bitly }->{ story_processing }->{ enabled } // '';

    return ( $enabled eq 'yes' );
}

# Schedule a story to be processed with Bit.ly later
sub add_to_processing_schedule($$)
{
    my ( $db, $stories_id ) = @_;

    unless ( story_processing_is_enabled() )
    {
        die "Bit.ly story processing is not enabled.";
    }

    return if ( _skip_processing_for_story_feed( $db, $stories_id ) );

    my $story = $db->find_by_id( 'stories', $stories_id );
    unless ( $story )
    {
        die "Story ID $stories_id was not found.";
    }

    my $config   = MediaWords::Util::Config::get_config();
    my $schedule = $config->{ bitly }->{ story_processing }->{ schedule };
    unless ( $schedule and ref( $schedule ) eq ref( [] ) )
    {
        die "Bit.ly processing schedule is not configured.";
    }

    my $now             = DateTime->now()->epoch;
    my $use_transaction = !$db->in_transaction();

    $db->begin if ( $use_transaction );
    foreach my $delay ( @{ $schedule } )
    {

        my $story_timestamp      = _story_timestamp( $story );
        my $processing_timestamp = $story_timestamp + $delay;

        $db->query(
            <<EOF,
            INSERT INTO bitly_processing_schedule (stories_id, fetch_at)
            VALUES (?, to_timestamp(?))
EOF
            $stories_id, $processing_timestamp
        );
    }
    $db->commit if ( $use_transaction );
}

# Add a chunk of due stories for which we should fetch Bit.ly statistics to job
# broker's queue
#
# Returns: a number of stories that have been added to job broker's queue
sub process_due_schedule_chunk($;$)
{
    my ( $db, $chunk_size ) = @_;

    unless ( story_processing_is_enabled() )
    {
        die "Bit.ly story processing is not enabled.";
    }

    $chunk_size ||= 1000;

    INFO "Fetching chunk of up to $chunk_size stories to add to Bit.ly fetch queue...";

    $db->begin_work;

    my $stories_to_process = $db->query(
        <<EOF,
            SELECT DISTINCT stories_id
            FROM bitly_processing_schedule
            WHERE fetch_at <= NOW()
            ORDER BY stories_id
            LIMIT ?
EOF
        $chunk_size
    )->hashes;

    if ( scalar( @{ $stories_to_process } ) == 0 )
    {
        INFO "No more stories left to process.";
        return 0;
    }

    INFO "Processing " . scalar( @{ $stories_to_process } ) . " stories...";

    foreach my $story_to_process ( @{ $stories_to_process } )
    {
        my $stories_id = $story_to_process->{ stories_id };

        DEBUG "Fetching story $stories_id...";
        my $story = $db->find_by_id( 'stories', $stories_id );
        unless ( $story )
        {
            die "Story ID $stories_id was not found.";
        }

        DEBUG "Calculating timestamps for story $stories_id...";
        my $story_timestamp = _story_timestamp( $story );
        my $start_timestamp = _story_start_timestamp( $story_timestamp );
        my $end_timestamp   = _story_end_timestamp( $story_timestamp );

        INFO "Adding story $stories_id to Bit.ly fetch queue...";
        MediaWords::Job::Bitly::FetchStoryStats->add_to_queue(
            {
                stories_id      => $stories_id,
                start_timestamp => $start_timestamp,
                end_timestamp   => $end_timestamp
            }
        );

        DEBUG "Removing story $stories_id from Bit.ly processing schedule...";
        $db->query(
            <<EOF,
            DELETE FROM bitly_processing_schedule
            WHERE stories_id = ?
              AND fetch_at <= NOW()
EOF
            $stories_id
        );

        DEBUG "Done processing story $stories_id.";
    }

    $db->commit;

    my $stories_processed = scalar( @{ $stories_to_process } );
    INFO "Done processing $stories_processed stories.";

    return $stories_processed;
}

1;
