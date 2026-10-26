package refactor

import "testing"

func TestFlixVersionOfSkipsTheJVMBanner(t *testing.T) {
	out := "Picked up JAVA_TOOL_OPTIONS: -Dhttps.proxyHost=127.0.0.1 -Dhttps.proxyPort=41451\nThe Flix Programming Language 0.78.0\n"
	if v := flixVersionOf(out); v != "0.78.0" {
		t.Errorf("版 %q（0.78.0 のはず）", v)
	}
	if v := flixVersionOf("Error: Unable to access jarfile 1.2.3\n"); v != "" {
		t.Errorf("Flix の行が無いのに %q", v)
	}
}
