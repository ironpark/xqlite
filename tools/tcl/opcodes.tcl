# tclsh opcodes.tcl PARSE.H VDBE.C MKOPCODEH.TCL > opcodes.h
#
# SQLite's main.mk runs `cat parse.h vdbe.c | tclsh mkopcodeh.tcl`; a
# build step has no pipe, so this script makes the concatenation the
# standard input of mkopcodeh.tcl (the first channel opened after stdin
# is closed takes its place) and runs it. For the TCL test harness
# (tools/tcl/README.md), whose helpers include sqliteInt.h.
lassign $argv parse_h vdbe_c script
set fd [file tempfile tmp]
fconfigure $fd -translation binary
foreach f [list $parse_h $vdbe_c] {
  set in [open $f rb]
  puts -nonewline $fd [read $in]
  close $in
}
close $fd
close stdin
open $tmp rb
set argv {}
source $script
file delete $tmp
