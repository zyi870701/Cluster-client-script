#!/usr/bin/env perl
use warnings; #sed replacement for -w perl parameter

# In general, doing
#  queue_battleship.pl some.log a b c is like running the command a b c in
# the bash shell, and putting the standard error and output into some.log.
# To run parallel jobs (backgrounded on the host machine), you can do (e.g.)
#  queue_battleship.pl JOB=1:4 some.JOB.log a b c JOB is like running the command a b c JOB
# and putting it in some.JOB.log, for each one. [Note: JOB can be any identifier].
# If any of the jobs fails, this script will fail.

# A typical example is:
#  queue_battleship.pl some.log my-prog "--opt=foo bar" foo \|  other-prog baz
# and queue_battleship.pl will run something like:
# ( my-prog '--opt=foo bar' foo |  other-prog baz ) >& some.log
#
# Basically it takes the command-line arguments, quotes them
# as necessary to preserve spaces, and evaluates them with bash.
# In addition it puts the command line at the top of the log, and
# the start and end times of the command at the beginning and end.
# The reason why this is useful is so that we can create a different
# version of this program that uses a queueing system instead.
#
$max_jobs_run = 200;
$jobstart = 1;
$jobend = 1;
$ignored_opts = ""; # These will be ignored.

$num_threads = 1;  # default: single thread
$gpu = 0;          # default: don't request gpu
$host_list = ""; # default: all hosts
$no_log_file = 0;  # default: use logfile

# use Data::Dumper;
$usage = <<"END";
usage: queue_battleship.pl [options] [JOB=1:10] log-file command-line arguments...

  options:
    --max-jobs-run <N> : number of jobs run concurrently. (default: $max_jobs_run)
    --gpu <N>          : number of GPUs required by each job. (default: $gpu)
    --num-threads <N>  : number of CPUs required by each job. (default: $num_threads)
    --host-list "list" : submit jobs to assigned hosts (seperated by ':', default: all hosts)
    --no-log-file      : skip log-file(in command), use stdin, stdout instead(jobs # = 1)
      
END

@ARGV < 2 && die $usage;

# First parse an option like JOB=1:4, and any
# options that would normally be given to
# queue.pl, which we will just discard.

for (my $x = 1; $x <= 2; $x++) { # This for-loop is to
  # allow the JOB=1:n option to be interleaved with the
  # options to qsub.
  while (@ARGV >= 2 - $no_log_file && $ARGV[0] =~ m:^-:) {
    # parse any options that would normally go to qsub, but which will be ignored here.
    my $switch = shift @ARGV;
    if ($switch eq "-V") {
      $ignored_opts .= "-V ";
    } elsif ($switch eq "--max-jobs-run" || $switch eq "-tc") {
      # we do support the option --max-jobs-run n, and its GridEngine form -tc n.
      $max_jobs_run = shift @ARGV;
      if (! ($max_jobs_run > 0)) {
        die "queue_battleship.pl: invalid option --max-jobs-run $max_jobs_run";
      }
    } elsif ($switch eq "--gpu"){
       $gpu = shift @ARGV;
       if ($gpu < 0){
          die "queue_battleship.pl: invalid option --gpu $gpu";
       }
    } elsif ($switch eq "-l"){
       $opts = shift @ARGV;
       foreach (split(',', $opts)){
          if( $_ =~ /(.*)=(.*)/){
             if($1 eq "gpu"){
                $gpu=$2;
             }
          }
       }
    } elsif ($switch eq "--num-threads"){
       $num_threads = shift @ARGV;
       if($num_threads <= 0){
          die "queue_battleship.pl: invalid option --num-threads $num_threads";
       }
    } elsif ($switch eq "--host-list"){
       $host_list = shift @ARGV;
    } elsif ($switch eq "--no-log-file"){
       $no_log_file = 1
    } else {
      my $argument = shift @ARGV;
      if ($argument =~ m/^--/) {
        print STDERR "WARNING: suspicious argument '$argument' to $switch; starts with '-'\n";
      }
      if ($switch eq "-sync" && $argument =~ m/^[yY]/) {
        $ignored_opts .= "-sync "; # Note: in the
        # corresponding code in queue.pl it says instead, just "$sync = 1;".
      } elsif ($switch eq "-pe") { # e.g. -pe smp 5
        my $argument2 = shift @ARGV;
        $ignored_opts .= "$switch $argument $argument2 ";
      } elsif ($switch =~ m/^--/) { # Config options
        # Convert CLI new-style options
        # Ignore all options
        $ignored_opts .= "$switch $argument ";
      } else {  # Other qsub options - passed as is
        $ignored_opts .= "$switch $argument ";
      }
    }
  }
  @ARGV < 2 - $no_log_file && die $usage;
  if ($ARGV[0] =~ m/^([\w_][\w\d_]*)+=(\d+):(\d+)$/) { # e.g. JOB=1:20
    $jobname = $1;
    $jobstart = $2;
    $jobend = $3;
    shift;
    if ($jobstart > $jobend) {
      die "queue_battleship.pl: invalid job range $ARGV[0]";
    }
    if ($jobstart <= 0) {
      die "queue_battleship.pl: invalid job range $ARGV[0], start must be strictly positive (this is required for GridEngine compatibility).";
    }
  } elsif ($ARGV[0] =~ m/^([\w_][\w\d_]*)+=(\d+)$/) { # e.g. JOB=1.
    $jobname = $1;
    $jobstart = $2;
    $jobend = $2;
    shift;
  } elsif ($ARGV[0] =~ m/.+\=.*\:.*$/) {
    print STDERR "queue_battleship.pl: Warning: suspicious first argument to queue_battleship.pl: $ARGV[0]\n";
  }
}

@ARGV < 2 - $no_log_file && die $usage;
# Users found this message confusing so we are removing it.
if ($ignored_opts ne "") {
  print STDERR "queue_battleship.pl: Warning: ignoring options \"$ignored_opts\"\n";
}

if($no_log_file){
   $jobstart != $jobend && die $usage;
}else{
   $logfile = shift @ARGV;
}

if (defined $jobname && $logfile !~ m/$jobname/ &&
    $jobend > $jobstart) {
  print STDERR "queue_battleship.pl: you are trying to run a parallel job but "
    . "you are putting the output into just one log file ($logfile)\n";
  exit(1);
}

$cmd = "";

foreach $x (@ARGV) {
    if ($x =~ m/^\S+$/) { $cmd .=  $x . " "; }
    elsif ($x =~ m:\":) { $cmd .= "'$x' "; }
    else { $cmd .= "\"$x\" "; }
}

#$Data::Dumper::Indent=0;
$ret = 0;
$numfail = 0;
%active_pids=();
%pid=();

use POSIX ":sys_wait_h";
for ($jobid = $jobstart; $jobid <= $jobend; $jobid++) {
  if (scalar(keys %active_pids) >= $max_jobs_run) {

    # Lets wait for a change in any child's status
    # Then we have to work out which child finished
    $r = waitpid(-1, 0);
    $code = $?;
    if ($r < 0 ) { die "queue_battleship.pl: Error waiting for child process"; } # should never happen.
    if ( defined $active_pids{$r} ) {
        $jid=$active_pids{$r};
        $fail[$jid]=$code;
        if ($code !=0) { $numfail++;}
        delete $active_pids{$r};
        # print STDERR "Finished: $r/$jid " .  Dumper(\%active_pids) . "\n";
    } else {
        die "queue_battleship.pl: Cannot find the PID of the chold process that just finished.";
    }

    # In theory we could do a non-blocking waitpid over all jobs running just
    # to find out if only one or more jobs finished during the previous waitpid()
    # However, we just omit this and will reap the next one in the next pass
    # through the for(;;) cycle
  }
  $childpid = fork();
  if (!defined $childpid) { die "queue_battleship.pl: Error forking in queue_battleship.pl (writing to $logfile)"; }
  if ($childpid == 0) { # We're in the child... this branch
    # executes the job and returns (possibly with an error status).
    if (defined $jobname) {
      $cmd =~ s/$jobname/$jobid/g;
      $logfile =~ s/$jobname/$jobid/g;
    }

    $gethosttime = `date +'%s'`;

    @array = split(' ', `gethost.pl $gpu $num_threads $host_list`);
    $host   = $array[0];
    $gpu_id = $array[1];

    $SIG{INT} = $SIG{TERM} = sub { if($host){ system("puthost.pl $host $gpu $num_threads $gpu_id");  $host=""; } };

    $env  = `export | tr '\n' ';'`;
    $pwd  = `pwd`;
    $pwd  =~  s/\R//g;


    if($no_log_file == 1){
       # Pipe into bash.. make sure we're not using any other shell.
       $cmd_str = '';
       $cmd_str = $cmd_str . "$env cd $pwd;";
       $cmd_str = $cmd_str . "export CUDA_VISIBLE_DEVICES=$gpu_id;" if $gpu == 1;
       $cmd_str = $cmd_str . "$cmd";

       $ret = system("ssh -t -q $host '$cmd_str'");
    }else{
       system("mkdir -p `dirname $logfile` 2>/dev/null");
       open(F, ">$logfile") || die "queue_battleship.pl: Error opening log file $logfile";
       $starttime = `date +'%s'`;
       print F "######################\n";
       print F "# Wait " . ($starttime - $gethosttime) . " seconds to get host\n";
       print F "######################\n";
       close(F);

       my $queue_scriptfile = $logfile . ".sh";
       $queue_scriptfile = `touch $queue_scriptfile && readlink -f $queue_scriptfile`;
       $queue_scriptfile =~ s/\R//g; 

       open(Q, ">$queue_scriptfile") || die "Failed to write to $queue_scriptfile";

       print Q "#!/bin/bash\n";
       print Q "$env \n";
       print Q "cd $pwd\n";
       print Q "export CUDA_VISIBLE_DEVICES=$gpu_id\n" if $gpu == 1;
       print Q "( echo '#' Running on \`hostname\`\n";
       print Q "  echo '#' Started at \`date\`\n";
       print Q "  echo -n '# '; cat <<EOF\n";
       print Q "$cmd\n"; # this is a way of echoing the command into a comment in the log file,
       print Q "EOF\n"; # without having to escape things like "|" and quote characters.
       print Q ") >>$logfile\n";
       print Q "time1=\`date +\"%s\"\`\n";
       print Q " ( $cmd ) 2>>$logfile >>$logfile\n";
       print Q "ret=\$?\n";
       print Q "time2=\`date +\"%s\"\`\n";
       print Q "echo '#' Accounting: time=\$((\$time2-\$time1)) threads=$num_threads gpu=$gpu gpu_id=$gpu_id >>$logfile\n";
       print Q "echo '#' Finished at \`date\` with status \$ret >>$logfile\n";
       print Q "exit \$[\$ret ? 1 : 0]\n"; 
       if (!close(Q)) { # close was not successful... || die "Could not close script file $shfile";
          die "Failed to close the script file (full disk?)";
       }

       $ret = system("ssh -t -q $host 'while [ ! -e $queue_scriptfile ]; do sleep 1; done ; bash $queue_scriptfile'");
    }


    $lowbits = $ret & 127;
    $highbits = $ret >> 8;
    if ($lowbits != 0) { $return_str = "code $highbits; signal $lowbits" }
    else { $return_str = "code $highbits"; }

    system("puthost.pl $host $gpu $num_threads $gpu_id");
    $host="";

    exit($ret == 0 ? 0 : 1);
  } else {
    $pid[$jobid] = $childpid;
    $active_pids{$childpid} = $jobid;
    # print STDERR "Queued: " .  Dumper(\%active_pids) . "\n";
  }
}

# Now we have submitted all the jobs, lets wait until all the jobs finish
foreach $child (keys %active_pids) {
    $jobid=$active_pids{$child};
    $r = waitpid($pid[$jobid], 0);
    $code = $?;
    if ($r == -1) { die "queue_battleship.pl: Error waiting for child process"; } # should never happen.
    if ($r != 0) { $fail[$jobid]=$code; $numfail++ if $code!=0; } # Completed successfully
}

# Some sanity checks:
# The $fail array should not contain undefined codes
# The number of non-zeros in that array  should be equal to $numfail
# We cannot do foreach() here, as the JOB ids do not necessarily start by zero
$failed_jids=0;
for ($jobid = $jobstart; $jobid <= $jobend; $jobid++) {
  $job_return = $fail[$jobid];
  if (not defined $job_return ) {
    # print Dumper(\@fail);

    die "queue_battleship.pl: Sanity check failed: we have indication that some jobs are running " .
      "even after we waited for all jobs to finish" ;
  }
  if ($job_return != 0 ){ $failed_jids++;}
}
if ($failed_jids != $numfail) {
  die "queue_battleship.pl: Sanity check failed: cannot find out how many jobs failed ($failed_jids x $numfail)."
}
if ($numfail > 0) { $ret = 1; }

if ($ret != 0) {
  $njobs = $jobend - $jobstart + 1;
  if ($njobs == 1) {
    if (defined $jobname) {
      $logfile =~ s/$jobname/$jobstart/; # only one numbered job, so replace name with
                                         # that job.
    }
    if(defined $logfile){
       print STDERR "queue_battleship.pl: job failed, log is in $logfile\n";
       if ($logfile =~ m/JOB/) {
          print STDERR "queue_battleship.pl: probably you forgot to put JOB=1:\$nj in your script.";
       }
    }else{
       print STDERR "queue_battleship.pl: job failed\n";
    }
  }
  else {
    $logfile =~ s/$jobname/*/g;
    print STDERR "queue_battleship.pl: $numfail / $njobs failed, log is in $logfile\n";
  }
}


exit ($ret);
