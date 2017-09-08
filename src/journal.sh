# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   Name: journal.sh - part of the BeakerLib project
#   Description: Journalling functionality
#
#   Author: Petr Muller <pmuller@redhat.com>
#   Author: Jan Hutar <jhutar@redhat.com>
#   Author: Ales Zelinka <azelinka@redhat.com>
#   Author: Petr Splichal <psplicha@redhat.com>
#
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   Copyright (c) 2008-2010 Red Hat, Inc. All rights reserved.
#
#   This copyrighted material is made available to anyone wishing
#   to use, modify, copy, or redistribute it subject to the terms
#   and conditions of the GNU General Public License version 2.
#
#   This program is distributed in the hope that it will be
#   useful, but WITHOUT ANY WARRANTY; without even the implied
#   warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
#   PURPOSE. See the GNU General Public License for more details.
#
#   You should have received a copy of the GNU General Public
#   License along with this program; if not, write to the Free
#   Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
#   Boston, MA 02110-1301, USA.
#
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

: <<'=cut'
=pod

=head1 NAME

BeakerLib - journal - journalling functionality

=head1 DESCRIPTION

Routines for initializing the journalling features and pretty
printing journal contents.

=head1 FUNCTIONS

=cut

__INTERNAL_JOURNALIST=beakerlib-journalling
__INTERNAL_timeformat="%Y-%m-%d %H:%M:%S %Z"


# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# rlJournalStart
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
: <<'=cut'
=pod

=head2 Journalling

=head3 rlJournalStart

Initialize the journal file.

    rlJournalStart

Run on the very beginning of your script to initialize journalling
functionality.

=cut

rlJournalStart(){
    printf -v __INTERNAL_STARTTIME "%(%s)T" -1
    # test-specific temporary directory for journal/metadata
    if [ -n "$BEAKERLIB_DIR" ]; then
        # try user-provided temporary directory first
        true
    elif [ -n "$TESTID" ]; then
        # if available, use TESTID for the temporary directory
        # - this is useful for preserving metadata through a system reboot
        export BEAKERLIB_DIR="$__INTERNAL_PERSISTENT_TMP/beakerlib-$TESTID"
    else
        # else generate a random temporary directory
        export BEAKERLIB_DIR=$(mktemp -d $__INTERNAL_PERSISTENT_TMP/beakerlib-XXXXXXX)
    fi

    [ -d "$BEAKERLIB_DIR" ] || mkdir -p "$BEAKERLIB_DIR"

    # unless already set by user set global BeakerLib journal and meta file variables
    [ -z "$BEAKERLIB_JOURNAL" ] && export BEAKERLIB_JOURNAL="$BEAKERLIB_DIR/journal.xml"
    [ -z "$BEAKERLIB_METAFILE" ] && export BEAKERLIB_METAFILE="$BEAKERLIB_DIR/journal.meta"
    __INTERNAL_BEAKERLIB_JOURNAL_TXT="$(echo "$BEAKERLIB_JOURNAL" | sed -r 's/\.[^.]+$//').txt"
    __INTERNAL_BEAKERLIB_JOURNAL_COLORED="$(echo "$BEAKERLIB_JOURNAL" | sed -r 's/\.[^.]+$//')_colored.txt"

    # make sure the directory is ready, otherwise we cannot continue
    if [ ! -d "$BEAKERLIB_DIR" ] ; then
        echo "rlJournalStart: Failed to create $BEAKERLIB_DIR directory."
        echo "rlJournalStart: Cannot continue, exiting..."
        exit 1
    fi

    # creating queue file
    touch $BEAKERLIB_METAFILE

    # Initialization of variables holding current state of the test
    export __INTERNAL_METAFILE_INDENT_LEVEL=0
    __INTERNAL_PHASE_TYPE=()
    __INTERNAL_PHASE_NAME=()
    export __INTERNAL_PRESISTENT_DATA="$BEAKERLIB_DIR/PersistentData"
    export __INTERNAL_JOURNAL_OPEN=''
    __INTERNAL_PersistentDataLoad
    export __INTERNAL_PHASES_FAILED=0
    export __INTERNAL_PHASES_PASSED=0
    export __INTERNAL_PHASES_SKIPED=0
    export __INTERNAL_PHASES_WORST_RESULT='PASS'
    export __INTERNAL_TEST_STATE=0
    __INTERNAL_PHASE_TXTLOG_START=()
    __INTERNAL_PHASE_FAILED=()
    __INTERNAL_PHASE_PASSED=()
    __INTERNAL_PHASE_STARTTIME=()
    __INTERNAL_PHASE_METRICS=()
    export __INTERNAL_PHASE_OPEN=0

    if [[ -z "$__INTERNAL_JOURNAL_OPEN" ]]; then
      # Create Header for XML journal
      __INTERNAL_CreateHeader
      # Create log element for XML journal
      __INTERNAL_WriteToMetafile log
    fi
    __INTERNAL_JOURNAL_OPEN=1
    # Increase level of indent
    __INTERNAL_METAFILE_INDENT_LEVEL=1

    # display a warning message if run in POSIX mode
    if [ $POSIXFIXED == "YES" ] ; then
        rlLogWarning "POSIX mode detected and switched off"
        rlLogWarning "Please fix your test to have /bin/bash shebang"
    fi

    # final cleanup file (atomic updates)
    export __INTERNAL_CLEANUP_FINAL="$BEAKERLIB_DIR/cleanup.sh"
    # cleanup "buffer" used for append/prepend
    export __INTERNAL_CLEANUP_BUFF="$BEAKERLIB_DIR/clbuff"

    if touch "$__INTERNAL_CLEANUP_FINAL" "$__INTERNAL_CLEANUP_BUFF"; then
        rlLogDebug "rlJournalStart: Basic cleanup infrastructure successfully initialized"

        if [ -n "$TESTWATCHER_CLPATH" ] && \
           echo "$__INTERNAL_CLEANUP_FINAL" > "$TESTWATCHER_CLPATH"; then
            rlLogDebug "rlJournalStart: Running in test watcher and setup was successful"
            export __INTERNAL_TESTWATCHER_ACTIVE=true
        else
            rlLogDebug "rlJournalStart: Not running in test watcher or setup failed."
        fi
    else
        rlLogError "rlJournalStart: Failed to set up cleanup infrastructure"
    fi
    __INTERNAL_PersistentDataSave
}

# backward compatibility
rlStartJournal() {
    rlJournalStart
    rlLogWarning "rlStartJournal is obsoleted by rlJournalStart"
}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# rlJournalEnd
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
: <<'=cut'
=pod

=head3 rlJournalEnd

Summarize the test run and upload the journal file.

    rlJournalEnd

Run on the very end of your script to print summary of the whole test run,
generate OUTPUTFILE and include journal in Beaker logs.

=cut

rlJournalEnd(){
    if [ -z "$__INTERNAL_TESTWATCHER_ACTIVE" ] && [ -s "$__INTERNAL_CLEANUP_FINAL" ] && \
       [ -z "$__INTERNAL_CLEANUP_FROM_JOURNALEND" ]
    then
      rlLogWarning "rlJournalEnd: Not running in test watcher and rlCleanup* functions were used"
      rlLogWarning "rlJournalEnd: Executing prepared cleanup"
      rlLogWarning "rlJournalEnd: Please fix the test to use test watcher"

      # The executed cleanup will always run rlJournalEnd, so we need to prevent
      # infinite recursion. rlJournalEnd runs the cleanup only when
      # __INTERNAL_CLEANUP_FROM_JOURNALEND is not set (see above).
      __INTERNAL_CLEANUP_FROM_JOURNALEND=1 "$__INTERNAL_CLEANUP_FINAL"

      # Return, because the rest of the rlJournalEnd was already run inside the cleanup
      return $?
    fi

    if [ -z "$BEAKERLIB_COMMAND_SUBMIT_LOG" ]
    then
      local BEAKERLIB_COMMAND_SUBMIT_LOG="$__INTERNAL_DEFAULT_SUBMIT_LOG"
    fi

    if [ -n "$TESTID" ] ; then
        rlJournalWriteXML
        $BEAKERLIB_COMMAND_SUBMIT_LOG -T $TESTID -l $BEAKERLIB_JOURNAL \
        || rlLogError "rlJournalEnd: Submit wasn't successful"
    else
        rlLog "JOURNAL META: $BEAKERLIB_METAFILE"
        rlLog "JOURNAL XML: $BEAKERLIB_JOURNAL"
        rlLog "JOURNAL TXT: $__INTERNAL_BEAKERLIB_JOURNAL_TXT"
    fi

    echo "#End of metafile" >> $BEAKERLIB_METAFILE
    rlJournalWriteXML
}


# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# rlJournalWriteXML
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
: <<'=cut'
=pod

=head3 rlJournalWriteXML

Create XML version of the journal from internal structure.

    rlJournalWriteXML [--xslt file]

=over

=item --xslt file

Use xslt file to generate different journal format, e.g xUnit.

=back

=cut

rlJournalWriteXML() {
    local xslt=''
    [[ "$1" == "--xslt" ]] && [[ -r "$2" ]] && xslt="$1 $2"
    $__INTERNAL_JOURNALIST $xslt --metafile "$BEAKERLIB_METAFILE" --journal "$BEAKERLIB_JOURNAL"
}


# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# rlJournalPrint
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
: <<'=cut'
=pod

=head3 rlJournalPrint

Print the content of the journal in pretty xml format.

    rlJournalPrint [type]

This function is now deprecated due to journal rewrite and will be removed in
some of the future versions.

To achieve the pretty output call rlJournalWriteXML and `cat $BEAKERLIB_JOURNAL | xmllint --format - `.
To achieve the raw output call rlJournalWriteXML and `cat $BEAKERLIB_JOURNAL`.


=over

=item type

Can be either 'raw' or 'pretty', with the latter as a default.
Raw: xml is in raw form, no indentation etc
Pretty: xml is pretty printed, indented, with one record per line

=back

Example:

    <?xml version="1.0"?>
    <BEAKER_TEST>
      <test_id>debugging</test_id>
      <package>setup</package>
      <pkgdetails>setup-2.8.9-1.fc12.noarch</pkgdetails>
      <starttime>2010-02-08 15:17:47</starttime>
      <endtime>2010-02-08 15:17:47</endtime>
      <testname>/examples/beakerlib/Sanity/simple</testname>
      <release>Fedora release 12 (Constantine)</release>
      <hostname>localhost</hostname>
      <arch>i686</arch>
      <purpose>PURPOSE of /examples/beakerlib/Sanity/simple
        Description: Minimal BeakerLib sanity test
        Author: Petr Splichal &lt;psplicha@redhat.com&gt;

        This is a minimal sanity test for BeakerLib. It contains a single
        phase with a couple of asserts. We Just check that the "setup"
        package is installed and that there is a sane /etc/passwd file.
      </purpose>
      <log>
        <phase endtime="2010-02-08 15:17:47" name="Test" result="PASS"
                score="0" starttime="2010-02-08 15:17:47" type="FAIL">
          <test message="Checking for the presence of setup rpm">PASS</test>
          <test message="File /etc/passwd should exist">PASS</test>
          <test message="File '/etc/passwd' should contain 'root'">PASS</test>
        </phase>
      </log>
    </BEAKER_TEST>

=cut

# cat generated text version
rlJournalPrint(){
    rlLogWarning "$FUNCNAME(): this function was deprecated by the journal rewrite and will be removed in some of the future versions."
    rlLogInfo "$FUNCNAME(): to achieve the pretty output call rlJournalWriteXML and cat \$BEAKERLIB_JOURNAL | xmllint --format -"
    rlLogInfo "$FUNCNAME(): to achieve the raw output call rlJournalWriteXML and cat \$BEAKERLIB_JOURNAL"
}

# backward compatibility
rlPrintJournal() {
    rlLogWarning "rlPrintJournal is obsoleted by rlJournalPrint"
    rlJournalPrint
}


# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# rlJournalPrintText
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
: <<'=cut'
=pod

=head3 rlJournalPrintText

Print the content of the journal in pretty text format.

    rlJournalPrintText [--full-journal]

=over

=item --full-journal

The options is now deprecated, has no effect and will be removed in one
of future versions.

=back

Example:

    ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
    :: [   LOG    ] :: TEST PROTOCOL
    ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    :: [   LOG    ] :: Test run ID   : debugging
    :: [   LOG    ] :: Package       : debugging
    :: [   LOG    ] :: Test started  : 2010-02-08 14:45:57
    :: [   LOG    ] :: Test finished : 2010-02-08 14:45:58
    :: [   LOG    ] :: Test name     :
    :: [   LOG    ] :: Distro:       : Fedora release 12 (Constantine)
    :: [   LOG    ] :: Hostname      : localhost
    :: [   LOG    ] :: Architecture  : i686

    ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
    :: [   LOG    ] :: Test description
    ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    PURPOSE of /examples/beakerlib/Sanity/simple
    Description: Minimal BeakerLib sanity test
    Author: Petr Splichal <psplicha@redhat.com>

    This is a minimal sanity test for BeakerLib. It contains a single
    phase with a couple of asserts. We Just check that the "setup"
    package is installed and that there is a sane /etc/passwd file.


    ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
    :: [   LOG    ] :: Test
    ::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

    :: [   PASS   ] :: Checking for the presence of setup rpm
    :: [   PASS   ] :: File /etc/passwd should exist
    :: [   PASS   ] :: File '/etc/passwd' should contain 'root'
    :: [   LOG    ] :: Duration: 1s
    :: [   LOG    ] :: Assertions: 3 good, 0 bad
    :: [   PASS   ] :: RESULT: Test

=cut
# call rlJournalPrint
rlJournalPrintText(){
    local __INTERNAL_ENDTIME=$__INTERNAL_TIMESTAMP
    local duration=$(($__INTERNAL_ENDTIME - $__INTERNAL_STARTTIME))
    echo -e "\n\n\n\n"
    local textfile
    [[ -t 1 ]] && textfile="$__INTERNAL_BEAKERLIB_JOURNAL_COLORED" || textfile="$__INTERNAL_BEAKERLIB_JOURNAL_TXT"

    local sed_patterns="s/__INTERNAL_ENDTIME/$(printf "%($__INTERNAL_timeformat)T" $__INTERNAL_ENDTIME)/;s/__INTERNAL_DURATION/$duration seconds/"
    cat $textfile | sed -r "$sed_patterns"

    local tmp="$__INTERNAL_LogText_no_file"
    __INTERNAL_LogText_no_file=1
    __INTERNAL_PrintHeadLog "${TEST}" 2>&1
    __INTERNAL_LogText "Phases: $__INTERNAL_PHASES_PASSED good, $__INTERNAL_PHASES_FAILED bad" LOG 2>&1
    __INTERNAL_LogText "RESULT: $TEST" $__INTERNAL_PHASES_WORST_RESULT 2>&1
    __INTERNAL_LogText_no_file=$tmp

    return 0
}

# TODO_IMP implement with metafile solution
# backward compatibility
rlCreateLogFromJournal(){
    rlLogWarning "rlCreateLogFromJournal is obsoleted by rlJournalPrintText"
    rlJournalPrintText
}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# rlGetTestState
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
: <<=cut
=pod

=head3 rlGetTestState

Returns number of failed asserts in so far, 255 if there are more then 255 failures.
The precise number is set to ECODE variable.

    rlGetTestState
=cut

rlGetTestState(){
    __INTERNAL_PersistentDataLoad
    ECODE=$__INTERNAL_TEST_STATE
    rlLogDebug "rlGetTestState: $ECODE failed assert(s) in test"
    [[ $ECODE -gt 255 ]] && return 255 || return $ECODE
}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# rlGetPhaseState
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
: <<=cut
=pod

=head3 rlGetPhaseState

Returns number of failed asserts in current phase so far, 255 if there are more then 255 failures.
The precise number is set to ECODE variable.

    rlGetPhaseState
=cut

rlGetPhaseState(){
    __INTERNAL_PersistentDataLoad
    ECODE=$__INTERNAL_PHASE_FAILED
    rlLogDebug "rlGetPhaseState: $ECODE failed assert(s) in phase"
    [[ $ECODE -gt 255 ]] && return 255 || return $ECODE
}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Internal Stuff
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

rljAddPhase(){
    __INTERNAL_PersistentDataLoad
    local MSG=${2:-"Phase of $1 type"}
    local TXTLOG_START=$(wc -l $__INTERNAL_BEAKERLIB_JOURNAL_TXT)
    rlLogDebug "rljAddPhase: Phase $MSG started"
    __INTERNAL_WriteToMetafile phase --name "$MSG" --type "$1" >&2
    # Printing
    __INTERNAL_PrintHeadLog "$MSG"

    if [[ -z "$BEAKERLIB_NESTED_PHASES" ]]; then
      __INTERNAL_METAFILE_INDENT_LEVEL=2
      __INTERNAL_PHASE_TYPE=( "$1" )
      __INTERNAL_PHASE_NAME=( "$MSG" )
      __INTERNAL_PHASE_FAILED=( 0 )
      __INTERNAL_PHASE_PASSED=( 0 )
      __INTERNAL_PHASE_STARTTIME=( $__INTERNAL_TIMESTAMP )
      __INTERNAL_PHASE_TXTLOG_START=( $(wc -l $__INTERNAL_BEAKERLIB_JOURNAL_TXT) )
      __INTERNAL_PHASE_OPEN=${#__INTERNAL_PHASE_NAME[@]}
      __INTERNAL_PHASE_METRICS=( "" )
    else
      let __INTERNAL_METAFILE_INDENT_LEVEL+=1
      __INTERNAL_PHASE_TYPE=( "$1" "${__INTERNAL_PHASE_TYPE[@]}" )
      __INTERNAL_PHASE_NAME=( "$MSG" "${__INTERNAL_PHASE_NAME[@]}" )
      __INTERNAL_PHASE_FAILED=( 0 "${__INTERNAL_PHASE_FAILED[@]}" )
      __INTERNAL_PHASE_PASSED=( 0 "${__INTERNAL_PHASE_PASSED[@]}" )
      __INTERNAL_PHASE_STARTTIME=( $__INTERNAL_TIMESTAMP "${__INTERNAL_PHASE_STARTTIME[@]}" )
      __INTERNAL_PHASE_TXTLOG_START=( $TXTLOG_START "${__INTERNAL_PHASE_TXTLOG_START[@]}" )
      __INTERNAL_PHASE_OPEN=${#__INTERNAL_PHASE_NAME[@]}
      __INTERNAL_PHASE_METRICS=( "" "${__INTERNAL_PHASE_METRICS[@]}" )
    fi
    __INTERNAL_PersistentDataSave
}

__INTERNAL_SET_WORST_PHASE_RESULT() {
    local results='PASS WARN FAIL'
    [[ "$results" =~ $(echo "$__INTERNAL_PHASES_WORST_RESULT.*") ]] && {
      local possible_results="$BASH_REMATCH"
      rlLogDebug "$FUNCNAME(): possible worst results are now $possible_results, current result is $1"
      [[ "$possible_results" =~ $1 ]] && {
          rlLogDebug "$FUNCNAME(): changing worst phase result from $__INTERNAL_PHASES_WORST_RESULT to $1"
          __INTERNAL_PHASES_WORST_RESULT="$1"
      }
    }
}

rljClosePhase(){
    __INTERNAL_PersistentDataLoad
    [[ $__INTERNAL_PHASE_OPEN -eq 0 ]] && {
      rlLogError "nothing to close - no open phase"
      return 1
    }
    local result
    local logfile="$BEAKERLIB_DIR/journal.txt"

    local score=$__INTERNAL_PHASE_FAILED
    # Result
    if [ $score -eq 0 ]; then
        result="PASS"
        let __INTERNAL_PHASES_PASSED++
    else
        result="$__INTERNAL_PHASE_TYPE"
        let __INTERNAL_PHASES_FAILED+=1
    fi

    __INTERNAL_SET_WORST_PHASE_RESULT "$result"

    local name="$__INTERNAL_PHASE_NAME"

    rlLogDebug "rljClosePhase: Phase $name closed"
    local endtime; printf -v endtime "%(%s)T" -1
    __INTERNAL_LogText "________________________________________________________________________________"
    __INTERNAL_LogText "Duration: $((endtime - __INTERNAL_PHASE_STARTTIME))s" LOG
    __INTERNAL_LogText "Assertions: $__INTERNAL_PHASE_PASSED good, $__INTERNAL_PHASE_FAILED bad" LOG
    __INTERNAL_LogText "RESULT: $name" $result
    local logfile="$(mktemp)"
    tail -n +$((__INTERNAL_PHASE_TXTLOG_START+1)) $__INTERNAL_BEAKERLIB_JOURNAL_TXT > $logfile
    rlReport "$(echo "$name" | sed 's/[^[:alnum:]]\+/-/g')" "$result" "$score" "$logfile"
    rm -f $logfile

    # Reset of state variables
    if [[ -z "$BEAKERLIB_NESTED_PHASES" ]]; then
      __INTERNAL_METAFILE_INDENT_LEVEL=1
      __INTERNAL_PHASE_TYPE=()
      __INTERNAL_PHASE_NAME=()
      __INTERNAL_PHASE_FAILED=()
      __INTERNAL_PHASE_PASSED=()
      __INTERNAL_PHASE_STARTTIME=()
      __INTERNAL_PHASE_TXTLOG_START=()
      __INTERNAL_PHASE_METRICS=()
    else
      let __INTERNAL_METAFILE_INDENT_LEVEL-=1
      unset __INTERNAL_PHASE_TYPE[0]; __INTERNAL_PHASE_TYPE=( "${__INTERNAL_PHASE_TYPE[@]}" )
      unset __INTERNAL_PHASE_NAME[0]; __INTERNAL_PHASE_NAME=( "${__INTERNAL_PHASE_NAME[@]}" )
      [[ ${#__INTERNAL_PHASE_FAILED[@]} -gt 1 ]] && let __INTERNAL_PHASE_FAILED[1]+=__INTERNAL_PHASE_FAILED[0]
      unset __INTERNAL_PHASE_FAILED[0]; __INTERNAL_PHASE_FAILED=( "${__INTERNAL_PHASE_FAILED[@]}" )
      [[ ${#__INTERNAL_PHASE_PASSED[@]} -gt 1 ]] && let __INTERNAL_PHASE_PASSED[1]+=__INTERNAL_PHASE_PASSED[0]
      unset __INTERNAL_PHASE_PASSED[0]; __INTERNAL_PHASE_PASSED=( "${__INTERNAL_PHASE_PASSED[@]}" )
      unset __INTERNAL_PHASE_STARTTIME[0]; __INTERNAL_PHASE_STARTTIME=( "${__INTERNAL_PHASE_STARTTIME[@]}" )
      unset __INTERNAL_PHASE_TXTLOG_START[0]; __INTERNAL_PHASE_TXTLOG_START=( "${__INTERNAL_PHASE_TXTLOG_START[@]}" )
      unset __INTERNAL_PHASE_METRICS[0]; __INTERNAL_PHASE_METRICS=( "${__INTERNAL_PHASE_METRICS[@]}" )
    fi
    __INTERNAL_PHASE_OPEN=${#__INTERNAL_PHASE_NAME[@]}
    # Updating phase element
    __INTERNAL_WriteToMetafile --result "$result" --score "$score"
    __INTERNAL_PersistentDataSave
}

# $1 message
# $2 result
# $3 command
rljAddTest(){
    __INTERNAL_PersistentDataLoad
    if [ $__INTERNAL_PHASE_OPEN -eq 0 ]; then
        rlPhaseStart "FAIL" "Asserts collected outside of a phase"
        rlFail "TEST BUG: Assertion not in phase"
        rljAddTest "$@"
        rlPhaseEnd
    else
        __INTERNAL_LogText "$1" "$2"
        __INTERNAL_WriteToMetafile test --message "$1" ${3:+--command "$3"} -- "$2" >&2
        if [ "$2" == "PASS" ]; then
            let __INTERNAL_PHASE_PASSED+=1
        else
            let __INTERNAL_TEST_STATE+=1
            let __INTERNAL_PHASE_FAILED+=1
        fi
    fi
    __INTERNAL_PersistentDataSave
}

rljAddMetric(){
    __INTERNAL_PersistentDataLoad
    local MID="$2"
    local VALUE="$3"
    local TOLERANCE=${4:-"0.2"}
    local res=0
    if [ "$MID" == "" ] || [ "$VALUE" == "" ]
    then
        rlLogError "TEST BUG: Bad call of rlLogMetric"
        return 1
    fi
    if [[ "$__INTERNAL_PHASE_METRICS" =~ \ $MID\  ]]; then
        rlLogError "$FUNCNAME: Metric name not unique!"
        let res++
    else
        rlLogDebug "rljAddMetric: Storing metric $MID with value $VALUE and tolerance $TOLERANCE"
        __INTERNAL_PHASE_METRICS="$__INTERNAL_PHASE_METRICS $MID "
        __INTERNAL_WriteToMetafile metric --type "$1" --name "$MID" \
            --value "$VALUE" --tolerance "$TOLERANCE" >&2 || let res++
        __INTERNAL_PersistentDataSave
    fi
    return $?
}

rljAddMessage(){
    __INTERNAL_WriteToMetafile message --severity "$2" -- "$1" >&2
}

__INTERNAL_GetPackageDetails() {
    rpm -q "$1" --qf "%{name}-%{version}-%{release}.%{arch} %{sourcerpm}"
}

rljRpmLog(){
    local package_details
    if package_details=( $(__INTERNAL_GetPackageDetails "$1") ); then
        __INTERNAL_WriteToMetafile pkgdetails --sourcerpm "${package_details[1]}" -- "${package_details[0]}"
    else
        __INTERNAL_WriteToMetafile pkgnotinstalled -- "$1"
    fi
}


# determine SUT package
__INTERNAL_DeterminePackage(){
    local package="$PACKAGE"
    if [ "$PACKAGE" == "" ]; then
        if [ "$TEST" == "" ]; then
            package="unknown"
        else
            local arrPac=(${TEST//// })
            package=${arrPac[1]}
        fi
    fi
    echo "$package"
    return 0
}

# Creates header
__INTERNAL_CreateHeader(){

    __INTERNAL_PrintHeadLog "TEST PROTOCOL" 2> /dev/null

    [[ -n "$TESTID" ]] && {
        __INTERNAL_WriteToMetafile test_id -- "$TESTID"
        __INTERNAL_LogText "    Test run ID   : $TESTID" 2> /dev/null
    }

    # Determine package which is tested
    local package=$(__INTERNAL_DeterminePackage)
    __INTERNAL_WriteToMetafile package -- "$package"
    __INTERNAL_LogText "    Package       : $package" 2> /dev/null

    # Write package details (rpm, srcrpm) into metafile
    rljRpmLog "$package"
    package=( $(__INTERNAL_GetPackageDetails "$package") ) && \
        __INTERNAL_LogText "    Installed     : ${package[0]}" 2> /dev/null

    # RPM version of beakerlib
    package=( $(__INTERNAL_GetPackageDetails "beakerlib") ) && {
        __INTERNAL_WriteToMetafile beakerlib_rpm -- "${package[0]}"
        __INTERNAL_LogText "    beakerlib RPM : ${package[0]}" 2> /dev/null
    }

    # RPM version of beakerlib-redhat
    package=( $(__INTERNAL_GetPackageDetails "beakerlib-redhat") ) && {
        __INTERNAL_WriteToMetafile beakerlib_redhat_rpm -- "${package[0]}"
        __INTERNAL_LogText "    bl-redhat RPM : ${package[0]}" 2> /dev/null
    }

    local test_version="${testversion:-$TESTVERSION}"

    [[ -n "$test_version" ]] && {
        __INTERNAL_WriteToMetafile testversion -- "$test_version"
        __INTERNAL_LogText "    Test version  : $test_version" 2> /dev/null
    }

    package="${packagename:-$test_version}"
    local test_built
    [[ -n "$package" ]] && test_built=$(rpm -q --qf '%{BUILDTIME}\n' $package | head -n 1) && {
      printf -v test_built "%($__INTERNAL_timeformat)T" $test_built
      __INTERNAL_WriteToMetafile testversion -- "$test_built"
      __INTERNAL_LogText "    Test built    : $test_built" 2> /dev/null
    }


    # Starttime and endtime
    __INTERNAL_WriteToMetafile starttime
    __INTERNAL_WriteToMetafile endtime
    __INTERNAL_LogText "    Test started  : $(printf "%($__INTERNAL_timeformat)T" $__INTERNAL_STARTTIME)" 2> /dev/null
    __INTERNAL_LogText "    Test finished : __INTERNAL_ENDTIME" 2> /dev/null
    __INTERNAL_LogText "    Test duration : __INTERNAL_DURATION" 2> /dev/null

    # Test name
    TEST="${TEST:-unknown}"
    __INTERNAL_WriteToMetafile testname -- "${TEST}"
    __INTERNAL_LogText "    Test name     : ${TEST}" 2> /dev/null

    # OS release
    local release=$(cat /etc/redhat-release)
    [[ -n "$release" ]] && {
        __INTERNAL_WriteToMetafile release -- "$release"
        __INTERNAL_LogText "    Distro        : ${release}" 2> /dev/null
    }

    # to avoid using python let's try hostname, hopefully it will give good enough result in real env
    local hostname=$(hostname --fqdn)
    [[ -n "$hostname" ]] && {
        __INTERNAL_WriteToMetafile hostname -- "$hostname"
        __INTERNAL_LogText "    Hostname      : ${hostname}" 2> /dev/null
    }

    # Architecture # MEETING is it the correct way?
    local arch=$(uname -i 2>/dev/null || uname -m)
    [[ -n "$arch" ]] && {
        __INTERNAL_WriteToMetafile arch -- "$arch"
        __INTERNAL_LogText "    Architecture  : ${arch}" 2> /dev/null
    }

    local line size
    # CPU info
    if [ -f "/proc/cpuinfo" ]; then
        local count=0
        local type=""
        local cpu_regex="^model\sname.*: (.*)$"
        while read line; do
            if [[ "$line" =~ $cpu_regex ]]; then
                type="${BASH_REMATCH[1]}"
                let count++
            fi
        done < "/proc/cpuinfo"
        __INTERNAL_WriteToMetafile hw_cpu -- "$count x $type"
        __INTERNAL_LogText "    CPUs          : $count x $type" 2> /dev/null
    fi

    # RAM size
     if [[ -f "/proc/meminfo" ]]; then
        size=0
        local ram_regex="^MemTotal: *(.*) kB$"
        while read line; do
            if [[ "$line" =~ $ram_regex ]]; then
                size=`expr ${BASH_REMATCH[1]} / 1024`
                break
            fi
        done < "/proc/meminfo"
        __INTERNAL_WriteToMetafile hw_ram -- "$size MB"
        __INTERNAL_LogText "    RAM size      : ${size} MB" 2> /dev/null
    fi

    # HDD size
    size=0
    local hdd_regex="^(/[^ ]+) +([0-9]+) +[0-9]+ +[0-9]+ +[0-9]+% +[^ ]+$"
    while read -r line ; do
        if [[ "$line" =~ $hdd_regex ]]; then
            let size+=BASH_REMATCH[2]
        fi
    done < <(df -k -P --local --exclude-type=tmpfs)
    [[ -n "$size" ]] && {
        size="$(echo "$((size*100/1024/1024))" | sed -r 's/..$/.\0/') GB"
        __INTERNAL_WriteToMetafile hw_hdd -- "$size"
        __INTERNAL_LogText "    HDD size      : ${size}" 2> /dev/null
    }

    # Purpose
    [[ -f 'PURPOSE' ]] && {
        local purpose tmp
        mapfile -t tmp < PURPOSE
        printf -v purpose "%s\n" "${tmp[@]}"
        __INTERNAL_WriteToMetafile purpose -- "$purpose"
        __INTERNAL_PrintHeadLog "Test description" 2> /dev/null
        __INTERNAL_LogText "$purpose" 2> /dev/null
    }

    return 0
}


# Encode arguments' values into base64
# Adds --timestamp argument and indent
# writes it into metafile
# takes [element] --attribute1 value1 --attribute2 value2 .. [-- "content"]
__INTERNAL_WriteToMetafile(){
    printf -v __INTERNAL_TIMESTAMP '%(%s)T' -1
    local indent
    local line=""
    local lineraw=''
    local ARGS=("$@")
    local element=''

    [[ "${1:0:2}" != "--" ]] && {
      local element="$1"
      shift
    }
    local arg
    while [[ $# -gt 0 ]]; do
      case $1 in
      --)
        line+=" -- \"$(echo -n "$2" | base64 -w 0)\""
        printf -v lineraw "%s -- %q" "$lineraw" "$2"
        shift 2
        break
        ;;
      --*)
        line+=" $1=\"$(echo -n "$2" | base64 -w 0)\""
        printf -v lineraw "%s %s=%q" "$lineraw" "$1" "$2"
        shift
        ;;
      *)
        __INTERNAL_LogText "unexpected meta input format"
        set | grep ^ARGS=
        exit 124
        ;;
      esac
      shift
    done
    [[ $# -gt 0 ]] && {
      __INTERNAL_LogText "unexpected meta input format"
      set | grep ^ARGS=
      exit 125
    }

    printf -v indent '%*s' $__INTERNAL_METAFILE_INDENT_LEVEL

    line="$indent${element:+$element }--timestamp=\"${__INTERNAL_TIMESTAMP}\"$line"
    lineraw="$indent${element:+$element }--timestamp=\"${__INTERNAL_TIMESTAMP}\"$lineraw"
    echo "#${lineraw:1}" >> $BEAKERLIB_METAFILE
    echo "$line" >> $BEAKERLIB_METAFILE
}

__INTERNAL_PrintHeadLog() {
    __INTERNAL_LogText "\n::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::"
    __INTERNAL_LogText "::   $1"
    __INTERNAL_LogText "::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::\n"
}


# whenever any of the persistend variable is touched,
# functions __INTERNAL_PersistentDataLoad and __INTERNAL_PersistentDataSave
# should be called before and after that respectively.

__INTERNAL_PersistentDataSave() {
  cat > "$__INTERNAL_PRESISTENT_DATA" <<EOF
__INTERNAL_STRATTIME=$__INTERNAL_STRATTIME
__INTERNAL_TEST_STATE=$__INTERNAL_TEST_STATE
__INTERNAL_PHASES_FAILED=$__INTERNAL_PHASES_FAILED
__INTERNAL_JOURNAL_OPEN=$__INTERNAL_JOURNAL_OPEN
__INTERNAL_SET_WORST_PHASE_RESULT=$__INTERNAL_SET_WORST_PHASE_RESULT
EOF
declare -p __INTERNAL_PHASE_FAILED >> $__INTERNAL_PRESISTENT_DATA
declare -p __INTERNAL_PHASE_PASSED >> $__INTERNAL_PRESISTENT_DATA
declare -p __INTERNAL_PHASE_STARTTIME >> $__INTERNAL_PRESISTENT_DATA
declare -p __INTERNAL_PHASE_TXTLOG_START >> $__INTERNAL_PRESISTENT_DATA
declare -p __INTERNAL_PHASE_METRICS >> $__INTERNAL_PRESISTENT_DATA
}

__INTERNAL_PersistentDataLoad() {
  [[ -r "$__INTERNAL_PRESISTENT_DATA" ]] && . "$__INTERNAL_PRESISTENT_DATA"
}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# AUTHORS
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
: <<'=cut'
=pod

=head1 AUTHORS

=over

=item *

Petr Muller <pmuller@redhat.com>

=item *

Jan Hutar <jhutar@redhat.com>

=item *

Ales Zelinka <azelinka@redhat.com>

=item *

Petr Splichal <psplicha@redhat.com>

=back

=cut
