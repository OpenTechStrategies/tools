#!/usr/bin/perl
#
# Subroutines for ImportCSV job called by wikid.pl (Organic Design wiki daemon)
#
# @author Aran Dunkley http://www.organicdesign.co.nz/nad
#

sub initImportCSV {
	$$::job{'titles'} = {};
	$$::job{'work'} = [];
	my $file = $$::job{'file'};

	# Index the byte offsets of each line in the source file
	my $offset = 0;
	if ( open INPUT, "<$file" && open INDEX, "+>$file.idx" ) {
		while ( <INPUT> ) {
			print INDEX pack 'N', $offset;
			$offset = tell INPUT;
		}
		close INPUT;
		close INDEX;
    }
    
	# Couldn't open file
    else {
		workLogError( "Couldn't open input file \"$file\", job aborted!" );
		workStopJob();
	}	

	$$::job{'index'} = \@index;
	$$::job{'length'} = $#index;

	1;
}

sub mainImportCSV {
	my $wiki   = $$::job{'wiki'};
	my $file   = $$::job{'file'};
	my $wptr   = $$::job{'wptr'};
	my $offset = $$::job{'index'}[$wptr];
	my $length = $$::job{'index'}[$wptr + 1] - $offset;
	$$::job{'status'} = "Processing record $ptr";

	# Read the current line from the input file
	seek INPUT, $offset, 0;
	read INPUT, $line, $length;
	close INPUT;

	# Find the offset to the current line from the index file
	open INDEX, "<$file.idx";
	my $size = length pack 'N', 0;
	seek INDEX, $size * $wptr, 0;
	read INDEX, my $offset, $size;
	$offset = unpack( 'N', $offset );
	close INDEX;

	# Read the CSV record from the indexed offset
	open INPUT, "<$file";
	seek INPUT, $offset, 0;
	my $data = <INPUT>;
	close INPUT;

	# If this is the first row, define the columns
	if ( $wptr == 0 ) {
	}
	
	# Otherwise construct record as wikitext and insert into wiki
	else {
		my $cur = wikiRawPage( $wiki, $title );
		$$::job{'revisions'}++ if wikiEdit( $wiki, $title, $text, "Content imported from \"$file\"" ) && $cur ne $text;
	}

	1;
}

sub stopImportCSV {
	1;
}
