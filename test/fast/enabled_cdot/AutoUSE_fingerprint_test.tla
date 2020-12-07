---- MODULE AutoUSE_fingerprint_test ----
(* Test that proof obligations with AutoUSE
are fingerprinted after automated expansion
of definitions.

Run `tlapm` to create fingerprints,
edit the input file to make the proof obligation unprovable,
and re-run `tlapm` to ensure that the saved fingerprint does
not shadow the change of the defined operator `A` that is
expanded by `AutoUSE`.
*)
EXTENDS TLAPS


VARIABLE x


A == x' = 1


THEOREM ENABLED A
BY ExpandENABLED, AutoUSE

====================================
command: ${TLAPM} --toolbox 0 0 ${FILE}
stderr: All 3 obligations proved
command: sed -i "" -e "18s/A == x' = 1/A == x' # x'/" AutoUSE_fingerprint_test.tla
command: ${TLAPM} --toolbox 0 0 ${FILE}
stderr: obligations failed
command: sed -i "" -e "18s/A == x' # x'/A == x' = 1/" AutoUSE_fingerprint_test.tla
