#!/usr/bin/env bats

setup() {
    load '../helpers/test_helper'
    _common_setup
    load '../helpers/mock_claude'
    setup_mock_claude
}

teardown() {
    _common_teardown
}

@test "--help exits 0 and shows usage" {
    run bash "$PROJECT_ROOT/ultrainit.sh" --help
    assert_success
    assert_output --partial "Usage"
}

@test "-h exits 0 and shows usage" {
    run bash "$PROJECT_ROOT/ultrainit.sh" -h
    assert_success
    assert_output --partial "Usage"
}
