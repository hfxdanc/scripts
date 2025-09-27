#!/usr/bin/perl -w
#
# dhcp119
# John Simpson <jms1@jms1.net> 2016-07-31
#
# Shows the raw value needed for DHCP option 119, aka "domain-search", for
# one or more domain names.
#
# Implements DNS compression as described in RFC 3397, using the scheme
# originally described in RFC 1035 section 4.1.4.
#   https://tools.ietf.org/search/rfc1035#section-4.1.4
#
###############################################################################
#
# MIT License
#
# Copyright (c) 2016 John Simpson
#
# Permission is hereby granted, free of charge, to any person obtaining a
# copy of this software and associated documentation files (the "Software"),
# to deal in the Software without restriction, including without limitation
# the rights to use, copy, modify, merge, publish, distribute, sublicense,
# and/or sell copies of the Software, and to permit persons to whom the
# Software is furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included
# in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
# OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
# THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
# FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
# DEALINGS IN THE SOFTWARE.
#
###############################################################################

require 5.003 ;
use strict ;

use Getopt::Std ;

my %opt         = () ;
my $do_debug    = 0 ;   # -d
my $allow_ext   = 0 ;   # -e

###############################################################################

sub usage(;$)
{
    my $msg = ( shift || '' ) ;

    print <<EOF ;
$0 [-e] [-d] [-h] domain [...]

Shows the raw value needed for DHCP option 119, aka "domain-search", for
one or more domain names. Implements DNS compression as described in
RFC 3397.

-e      Allow extended characters. The original DNS standard, RFC 1034,
        required that DNS labels could contain only letters, digits, and
        hyphens. The rules have since been relaxed, and any character is
        technically allowed, although they tend to be avoided except for
        international names.

-d      Debugging. Shows the internal table of domain names and positions,
        used for DNS compression.

-h      Show this help message.

EOF

    if ( $msg )
    {
        print $msg ;
        exit 1 ;
    }

    exit 0 ;
}

###############################################################################
###############################################################################
###############################################################################
#
# Process the command line options

getopts( 'hde' , \%opt ) ;
$opt{'h'} && usage() ;
$do_debug   = ( $opt{'d'} ? 1 : 0 ) ;
$allow_ext  = ( $opt{'e'} ? 1 : 0 ) ;

###############################################################################
#
# Process the domain names on the command line

my $out = '' ;  # output as raw bytes
my %pos = () ;  # domain => position within $out
my @seq = () ;  # order that domains were added to $out (for debug output)

if ( $#ARGV < 0 )
{
    usage "ERROR: no domain names specified\n" ;
}

while ( my $name = shift @ARGV )
{
    ########################################
    # Make sure the name is a valid DNS domain name

    if ( length($name) > 255 )
    {
        die "ERROR: name \"$name\" is longer than 255 characters\n" ;
    }

    unless ( $allow_ext )
    {
        if ( $name =~ m|[^a-z0-9\-\.]|i )
        {
            die "ERROR: name \"$name\" contains invalid characters\n" ;
        }
    }

    ########################################
    # Process each label within the name

    my $remain      = $name ;
    my $compressed  = 0 ;

    while ( $remain ne '' )
    {
        ########################################
        # If the remaining name has already been seen,
        # * add a reference to it to the output
        # * remember that it's a compressed name
        #   (so we don't end with "00")
        # * we're finished with this name

        if ( exists $pos{$remain} )
        {
            $out .= "\xC0" . chr( $pos{$remain} ) ;
            $remain = '' ;
            $compressed = 1 ;
            last ;
        }

        ########################################
        # Remember the name we're adding, in case
        # a later name needs to refer back to it

        $pos{$remain} = length( $out ) ;
        push( @seq , $remain ) ;

        ########################################
        # Extract the first label from the remaining name

        my ( $label , $x ) = split( /\./ , $remain , 2 ) ;
        $remain = ( $x || '' ) ;

        if ( length($label) > 63 )
        {
            die "ERROR: label \"$label\" is longer than 63 characters\n" ;
        }

        ########################################
        # Add the length followed by the label itself to the output string

        $out .= chr( length( $label ) ) . $label ;
    }

    ########################################
    # If we didn't end with a compression reference,
    # add a zero byte to end this name.

    unless ( $compressed )
    {
        $out .= "\x00" ;
    }
}

if ( length( $out ) > 255 )
{
    die "ERROR: the output string is larger than 255 bytes\n" ;
}

########################################
# Show $out as a sequence of hex numbers

map { printf '%02X' , ord $_ } split( // , $out ) ;
print "\n" ;

########################################
# Debugging - show the entries in %pos

if ( $do_debug )
{
    print "\n" ;
    map { printf "%02X %s\n" , $pos{$_} , $_ } @seq ;
}
