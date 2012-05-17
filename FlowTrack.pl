#!/usr/bin/env perl
#
# Copyright 2012 Andrew Williams <andrew@manor.org>
#
# This file contains most of the top level interaction code.  For the actual processing and work
# see FlowTrack.pm
#
# For Documentation & License see the README
#
use strict;
use warnings;
use IO::Socket::INET;
use Net::Flow qw(decode);
use Data::Dumper;
use Net::IP;
use POE;
use POE::Wheel::Run;
use POE::Component::Server::HTTP;
use Time::HiRes;
use FT::FlowTrack;
use FT::FlowTrackWeb;
use HTTP::Status;
use autodie;

# Some configuration
my $PORT           = 2055;
my $DATAGRAM_LEN   = 1548;
my $PURGE_INTERVAL = 15;
my $DBNAME = "FlowTrack.sqlite";

my $VERBOSE = 1;

#
# Setup the POE session(s) and start them
#
main();

sub main
{
    my ($new_db_name) = @ARGV;

    $DBNAME = $new_db_name if(defined($new_db_name) && $new_db_name ne "");
    
    POE::Session->create(
        inline_states => {
            _start       => \&server_start,
            get_datagram => \&server_read,
            store_data   => \&store_data,
        }
    );
    POE::Kernel->run();
    exit 0;
}

#
# Main init code.  Start the listen loop, setup the data store job
# Evcentually will fork off the webserver
#
sub server_start
{
    my $kernel = $_[KERNEL];
    my $socket = IO::Socket::INET->new(
        Proto     => 'udp',
        LocalPort => $PORT
    );

    # Setup the database
    # TODO: Some of the init code should move ito
    #       FT/FlowTrack.pm
    # Quick and dirty for right now
    my $ft = FT::FlowTrack->new("./",1,$DBNAME);
    my $dbh = $ft->_initDB();
    $ft->_createTables();

    $_[HEAP]->{FlowTrack} = $ft;

# Not going to start the webserver right now.  Focus on flow collection    
#    my $child =
#      POE::Wheel::Run->new( Program => \&FT::FlowTrackWeb::ServerStart, );

    # Send a delayed message to store data
    $kernel->delay( store_data => $PURGE_INTERVAL );

    # Start off the select read.  use the get_datagram message
    $kernel->select_read( $socket, "get_datagram" );
}

#
# Do something with the data we've collected.  Reads the cached data out of heap and stores it.
# Called periodically (PURGE_INTERVAL) with a delayed message setup in server_start.  MUST RE-INJECT
# It's own delay.  (much like alarm)
#
sub store_data
{
    my $kernel    = $_[KERNEL];
    my $flow_data = $_[HEAP]->{'flows'};
    my $ft = $_[HEAP]->{FlowTrack};

    
    warn "Queued " . @{$flow_data} . "\n" if(defined($flow_data) && $VERBOSE);
    $ft->storeFlow($flow_data) if(defined($flow_data));

    # We've processed the flows, clear the heap for the next batch
    delete $_[HEAP]->{'flows'};

    # Restart the timer
    $kernel->delay( store_data => $PURGE_INTERVAL );
}

#
# This is where we read and process the netflow packet
# get_datagram event handler
#
sub server_read
{
    my ( $kernel, $socket ) = @_[ KERNEL, ARG0 ];
    my $packet           = undef;
    my $TemplateArrayRef = undef;
    my ( $HeaderHashRef, $FlowArrayRef, $ErrorsArrayRef ) = ();

    my $remote_address = $socket->recv( $packet, $DATAGRAM_LEN );

    # Get the decoded flow (is a list)
    my $decoded_packet = decode_packet($packet);

    # Put the decoded flow onto the HEAP for later storage (via store_data)
    push( @{ $_[HEAP]->{'flows'} }, @$decoded_packet );

}

#
# Actually do the packet decode
#
# TODO: Move packet/flow handling to a pm
#
sub decode_packet
{
    my ($packet) = @_;
    my $TemplateArrayRef = undef;
    my ( $HeaderHashRef, $FlowArrayRef, $ErrorsArrayRef ) = ();

    ( $HeaderHashRef, $TemplateArrayRef, $FlowArrayRef, $ErrorsArrayRef ) =
      Net::Flow::decode( \$packet, $TemplateArrayRef );

    return decode_netflow($FlowArrayRef);
}

#
# Make a usable datastructure out of the data from decode_packet
# Since we can get multiple records we're returning a list here
#
# TODO: Move packet/flow handling to a pm
#
sub decode_netflow
{
    my ($flow_struct) = @_;

    my $ret_list = [];

    foreach my $flow ( @{$flow_struct} )
    {
        my $tmp_struct = {};

        # The indicies of the data in $flow is documented in the netflow library
        # kind of a dumb way to do this, but it's not my module
        $tmp_struct->{fl_time} = Time::HiRes::time();
        $tmp_struct->{src_ip}  = $flow->{'8'};
        $tmp_struct->{dst_ip}  = $flow->{'12'};
        $tmp_struct->{src_port} = hex( unpack( "H*", $flow->{'7'} ) );
        $tmp_struct->{dst_port} = hex( unpack( "H*", $flow->{'11'} ) );
        $tmp_struct->{bytes}   = hex( unpack( "H*", $flow->{'1'} ) );
        $tmp_struct->{packets} = hex( unpack( "H*", $flow->{'2'} ) );

        push( @{$ret_list}, $tmp_struct );

    }

    return $ret_list;
}

