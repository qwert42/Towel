"---
Tests some of the stack instructions.
!>> 
!<< 42
0
1
"
import 'std' \
import '.w' \

(42 24 !!pop\Std !println\Std)

(21 !!dup\Std -\Std !println\Std)

(21 20 2 !!pack\Std -\Std` /apply\Std !println\Std)

"(1 2 [-\Std] !println\Std)"
