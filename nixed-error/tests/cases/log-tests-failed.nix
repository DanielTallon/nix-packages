# mode: build
# expect: build-failure
{ pkgs, ... }:
{
  system.build.nixedErrorCase = pkgs.runCommand "fancy-lib-1.2.3" { } ''
    echo "running test suite"
    echo "FAIL: test_parse (3 assertions)"
    echo "2 tests failed"
    exit 1
  '';
}
