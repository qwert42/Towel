"---
Some object-oriented programming sh**.
!>>
!<< 7
8
"

import 'std' @

bind ClassA fun` X,
  bind Data X
  then bind Accessor fun`, Data
       then [\Accessor]
       then bind Instance1-methods (7 ClassA)
     also Instance2-methods (8 ClassA)
     then bind Instance1-accessor (Instance1-methods #1)
          also Instance2-accessor (Instance2-methods #1)
          then (Instance1-accessor !println
	        Instance2-accessor !println)

