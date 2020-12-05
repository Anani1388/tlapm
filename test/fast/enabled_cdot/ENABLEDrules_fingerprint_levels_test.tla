---- MODULE ENABLEDrules_fingerprint_levels_test ----
(* Test that fingerprints do not mask change of level
of a proof step.

Run `tlapm` to create fingerprints.
Then, edit this file to change the level of an assumption
from state predicate to action. Re-run `tlapm` to ensure
that the saved fingerprint does not shadow the change of
the level of the assumption, at the proof step that
includes `ENABLEDrules`.
*)
EXTENDS TLAPS


VARIABLE x


THEOREM
    ASSUME x = 1
    PROVE ENABLED (x' = 1) => ENABLED (x' = 1 \/ x' = 2)
<1>1. (x' = 1) => (x' = 1 \/ x' = 2)
    OBVIOUS
<1> QED
    BY ONLY <1>1, ENABLEDrules


=====================================================
command: ${TLAPM} --toolbox 0 0 ${FILE}
stderr: All 4 obligations proved
command: sed -i "" -e "19s/ASSUME x = 1/ASSUME x' = 1/" ENABLEDrules_fingerprint_levels_test.tla
command: ${TLAPM} --toolbox 0 0 ${FILE}
stderr: obligations failed
command: sed -i "" -e "19s/ASSUME x' = 1/ASSUME x = 1/" ENABLEDrules_fingerprint_levels_test.tla
