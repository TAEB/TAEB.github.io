#!/usr/bin/env perl
use strict;
use warnings;

my $handle;

my %mon_no =
(
    Jan => '01',
    Feb => '02',
    Mar => '03',
    Apr => '04',
    May => '05',
    Jun => '06',
    Jul => '07',
    Aug => '08',
    Sep => '09',
    Oct => '10',
    Nov => '11',
    Dec => '12',
);

while (<>)
{
    if (/^--- Log opened (\w{3}) (\w{3}) (\d{2}) \d+:\d+:\d+ (\d{4})/
     || /^--- Day changed (\w{3}) (\w{3}) (\d{2}) (\d{4})/)
    {
        my ($wday, $mon, $day, $year) = ($1, $2, $3, $4);
        open $handle, '>>', "$year-$mon_no{$mon}-$day.txt";
    }
    else
    {
        print $handle $_;
    }
}

