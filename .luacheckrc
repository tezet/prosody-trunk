cache = true
read_globals = { "prosody", "hosts", "import" }
globals = { "_M" }
allow_defined_top = true
module = true
unused_secondaries = false
codes = true
ignore = { "411/err", "421/err", "411/ok", "421/ok", "211/_ENV" }

max_line_length = 150

files["core/"] = {
	read_globals = { "prosody", "hosts" };
	globals = { "prosody.hosts.?", "hosts.?" };
}
files["plugins/"] = {
	globals = { "module" };
}
files["tests/"] = {
	read_globals = {
		"testlib_new_env",
		"assert_equal",
		"assert_table",
		"assert_function",
		"assert_string",
		"assert_boolean",
		"assert_is",
		"assert_is_not",
		"runtest",
	};
}
