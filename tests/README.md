The Prefect Test Suite for Towel - the Test Suite from Betelgeuse
====

Prefect reads testcases per file from within the embeded multi-line comment in each file.

To create a test case: create a `.t` file, make a comment like this,

        "Some comments.
        ---
        Description for your test case, e.g. what does it test
        !>> Input for your testcase
        !<< Expected output for your testcase"

Single whitespace after `!>>` and `!<<` is optional.

To disable certain test, add two underscores to the beginning of its filename.

When you want to run these tests, go to the root directory of Towel and run

        ./waf configure --conf-test test

or

        ./waf test

Prefect will automatically discover all the available tests, i.e. those with the designated comments, and executes them to see if the output matches the expected output.
