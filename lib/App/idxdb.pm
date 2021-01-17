package App::idxdb;

# AUTHORITY
# DATE
# DIST
# VERSION

use 5.010001;
use strict;
use warnings;
use Log::ger;

use File::chdir;

sub _set_args_default {
    my $args = shift;
    if (!$args->{dbpath}) {
        require File::HomeDir;
        $args->{dbpath} = File::HomeDir->my_home . '/idxdb.db';
    }
}

sub _connect_db {
    require DBI;

    my ($dbpath, $mode) = @_;

    if ($mode eq 'ro') {
        # avoid creating the database file automatically if we are only in
        # read-only mode
        die "Can't find index '$dbpath'\n" unless -f $dbpath;
    }
    log_trace("Connecting to SQLite database at %s ...", $dbpath);
    DBI->connect("dbi:SQLite:database=$dbpath", undef, undef,
                 {RaiseError=>1});
}

sub _init {
    my ($args, $mode) = @_;

    unless ($App::idxdb::state) {
        _set_args_default($args);
        my $state = {
            #dbpath => $args->{dbpath},
            dbh => _connect_db($args->{dbpath}, $mode),
        };
        $App::idxdb::state = $state;
    }
    $App::idxdb::state;
}

our %SPEC;

$SPEC{':package'} = {
    v => 1.1,
    summary => 'IDX database',
};

our %args_common = (
    dbpath => {
        summary => 'Path for SQLite database',
        description => <<'_',

If not specified, will default to `~/idxdb.db`.

_
        schema => 'str*',
        tags => ['common'],
    },
);

$SPEC{update} = {
    v => 1.1,
    summary => 'Update data',
    args => {
        %args_common,
        gudangdata_path => {
            schema => 'dirname*',
            req => 1,
        },
    },
};
sub update {
    require DateTime;
    require DBIx::Util::Schema;
    require JSON::MaybeXS;

    my %args = @_;

    my $gd_path = $args{gudangdata_path};

    my $state = _init(\%args, 'rw');
    my $dbh = $state->{dbh};
    my $now = DateTime->now;

  UPDATE_DAILY_TRADING_SUMMARY:
    {
        my $table_exists = DBIx::Util::Schema::table_exists($dbh, 'daily_trading_summary');
        my @table_fields;
        if ($table_exists) {
            @table_fields = map { $_->{COLUMN_NAME} } DBIx::Util::Schema::list_columns($dbh, 'daily_trading_summary');
        }
        local $CWD = "$gd_path/table/idx_daily_trading_summary/raw";
      YEAR:
        for my $year (reverse glob("*")) {
            local $CWD = $year;
          FILENAME:
            for my $filename (reverse glob("*.json.gz")) {
                $filename =~ /^(\d{4})(\d{2})(\d{2})/ or die;
                log_trace "Processing file $CWD/$filename ...";
                my $date = "$1-$2-${3}";
                if ($table_exists && $dbh->selectrow_array(q(SELECT 1 FROM daily_trading_summary WHERE "Date" = ?), {}, $date)) {
                    log_debug "Data for date $date already exist, skipping this date";
                    next FILENAME;
                }
                open my $fh, "gzip -cd $filename |" or die "Can't open $filename: $!";
                my $data = JSON::MaybeXS::decode_json(join("", <$fh>));
                if (ref $data eq 'HASH' && $data->{data}) {
                    $data = $data->{data};
                }
                unless (@$data) {
                    log_debug "File $filename does not contain any records, skipping";
                    next FILENAME;
                }
                unless ($table_exists) {
                    $dbh->do("CREATE TABLE stock (code TEXT PRIMARY KEY, name TEXT NOT NULL, ctime INT NOT NULL, mtime INT NOT NULL)");
                    my @field_defs;
                    for my $key (sort keys %{ $data->[0] }) {
                        next if $key =~ /^(No|StockName)$/;
                        my $type;
                        $type = 'DECIMAL' if $key =~ /^(OpenPrice|Close|Previous|High|Low|Change|.*Volume|Previous|FirstTrade|.*Value|.*Frequency|IndexIndividual|Offer.*|Bid.*|.*Shares|Weight.*|Foreign.*)$/;
                        $type //= 'TEXT';
                        push @table_fields, $key;
                        push @field_defs, qq("$key" $type);
                    }
                    push @table_fields, "ctime", "mtime";
                    push @field_defs  , "ctime INT NOT NULL", "mtime INT NOT NULL";
                    $dbh->do("CREATE TABLE daily_trading_summary (".join(", ", @field_defs).")");
                    $dbh->do("CREATE INDEX ix_daily_trading_summary__StockCode ON daily_trading_summary(StockCode)");
                    $dbh->do("CREATE UNIQUE INDEX ix_daily_trading_summary__Date__StockCode ON daily_trading_summary(Date,StockCode)");
                }

                my $sth_sel_stock = $dbh->prepare("SELECT code FROM stock WHERE code=?");
                my $sth_ins_stock = $dbh->prepare("INSERT INTO stock (code,name,  ctime,mtime) VALUES (?,?,  ?,?)");
                my $sql = "INSERT INTO daily_trading_summary (".join(",", map {qq("$_")} @table_fields).") VALUES (".join(",", map {"?"} @table_fields).")";
                #log_warn $sql;
                my $sth_ins_daily_trading_summary = $dbh->prepare($sql);
                $dbh->begin_work;
                for my $row (@$data) {
                    $row->{Date} =~ s/T\d.+//;
                    $sth_sel_stock->execute($row->{StockCode});
                    my @row = $sth_sel_stock->fetchrow_array;
                    unless (@row) {
                        $sth_ins_stock->execute($row->{StockCode}, $row->{StockName}, time(), time());
                    }
                    $row->{ctime} = time();
                    $row->{mtime} = time();
                    $sth_ins_daily_trading_summary->execute((map { $row->{$_} } @table_fields));
                }
                $dbh->commit;
            }
        }
    } # UPDATE_DAILY_TRADING_SUMMARY

    [200];
}

1;
# ABSTRACT:

=head1 SYNOPSIS

See the included CLI script L<idxdb>.


=head1 DESCRIPTION

TBD


=head1 SEE ALSO
