
local st = require "util.stanza";

describe("util.stanza", function()
	describe("#preserialize()", function()
		it("should work", function()
			local stanza = st.stanza("message", { a = "a" });
			local stanza2 = st.preserialize(stanza);
			assert.is_string(stanza2 and stanza.name, "preserialize returns a stanza");
			assert.is_nil(stanza2.tags, "Preserialized stanza has no tag list");
			assert.is_nil(stanza2.last_add, "Preserialized stanza has no last_add marker");
			assert.is_nil(getmetatable(stanza2), "Preserialized stanza has no metatable");
		end);
	end);

	describe("#preserialize()", function()
		it("should work", function()
			local stanza = st.stanza("message", { a = "a" });
			local stanza2 = st.deserialize(st.preserialize(stanza));
			assert.is_string(stanza2 and stanza.name, "deserialize returns a stanza");
			assert.is_table(stanza2.attr, "Deserialized stanza has attributes");
			assert.are.equal(stanza2.attr.a, "a", "Deserialized stanza retains attributes");
			assert.is_table(getmetatable(stanza2), "Deserialized stanza has metatable");
		end);
	end);

	describe("#stanza()", function()
		it("should work", function()
			local s = st.stanza("foo", { xmlns = "myxmlns", a = "attr-a" });
			assert.are.equal(s.name, "foo");
			assert.are.equal(s.attr.xmlns, "myxmlns");
			assert.are.equal(s.attr.a, "attr-a");

			local s1 = st.stanza("s1");
			assert.are.equal(s1.name, "s1");
			assert.are.equal(s1.attr.xmlns, nil);
			assert.are.equal(#s1, 0);
			assert.are.equal(#s1.tags, 0);

			s1:tag("child1");
			assert.are.equal(#s1.tags, 1);
			assert.are.equal(s1.tags[1].name, "child1");

			s1:tag("grandchild1"):up();
			assert.are.equal(#s1.tags, 1);
			assert.are.equal(s1.tags[1].name, "child1");
			assert.are.equal(#s1.tags[1], 1);
			assert.are.equal(s1.tags[1][1].name, "grandchild1");

			s1:up():tag("child2");
			assert.are.equal(#s1.tags, 2, tostring(s1));
			assert.are.equal(s1.tags[1].name, "child1");
			assert.are.equal(s1.tags[2].name, "child2");
			assert.are.equal(#s1.tags[1], 1);
			assert.are.equal(s1.tags[1][1].name, "grandchild1");

			s1:up():text("Hello world");
			assert.are.equal(#s1.tags, 2);
			assert.are.equal(#s1, 3);
			assert.are.equal(s1.tags[1].name, "child1");
			assert.are.equal(s1.tags[2].name, "child2");
			assert.are.equal(#s1.tags[1], 1);
			assert.are.equal(s1.tags[1][1].name, "grandchild1");
		end);
		it("should work with unicode values", function ()
			local s = st.stanza("Объект", { xmlns = "myxmlns", ["Объект"] = "&" });
			assert.are.equal(s.name, "Объект");
			assert.are.equal(s.attr.xmlns, "myxmlns");
			assert.are.equal(s.attr["Объект"], "&");
		end);
		it("should allow :text() with nil and empty strings", function ()
			local s_control = st.stanza("foo");
			assert.same(st.stanza("foo"):text(), s_control);
			assert.same(st.stanza("foo"):text(nil), s_control);
			assert.same(st.stanza("foo"):text(""), s_control);
		end);
	end);

	describe("#message()", function()
		it("should work", function()
			local m = st.message();
			assert.are.equal(m.name, "message");
		end);
	end);

	describe("#iq()", function()
		it("should work", function()
			local i = st.iq();
			assert.are.equal(i.name, "iq");
		end);
	end);

	describe("#iq()", function()
		it("should work", function()
			local p = st.presence();
			assert.are.equal(p.name, "presence");
		end);
	end);

	describe("#reply()", function()
		it("should work for <s>", function()
			-- Test stanza
			local s = st.stanza("s", { to = "touser", from = "fromuser", id = "123" })
				:tag("child1");
			-- Make reply stanza
			local r = st.reply(s);
			assert.are.equal(r.name, s.name);
			assert.are.equal(r.id, s.id);
			assert.are.equal(r.attr.to, s.attr.from);
			assert.are.equal(r.attr.from, s.attr.to);
			assert.are.equal(#r.tags, 0, "A reply should not include children of the original stanza");
		end);

		it("should work for <iq get>", function()
			-- Test stanza
			local s = st.stanza("iq", { to = "touser", from = "fromuser", id = "123", type = "get" })
				:tag("child1");
			-- Make reply stanza
			local r = st.reply(s);
			assert.are.equal(r.name, s.name);
			assert.are.equal(r.id, s.id);
			assert.are.equal(r.attr.to, s.attr.from);
			assert.are.equal(r.attr.from, s.attr.to);
			assert.are.equal(r.attr.type, "result");
			assert.are.equal(#r.tags, 0, "A reply should not include children of the original stanza");
		end);

		it("should work for <iq set>", function()
			-- Test stanza
			local s = st.stanza("iq", { to = "touser", from = "fromuser", id = "123", type = "set" })
				:tag("child1");
			-- Make reply stanza
			local r = st.reply(s);
			assert.are.equal(r.name, s.name);
			assert.are.equal(r.id, s.id);
			assert.are.equal(r.attr.to, s.attr.from);
			assert.are.equal(r.attr.from, s.attr.to);
			assert.are.equal(r.attr.type, "result");
			assert.are.equal(#r.tags, 0, "A reply should not include children of the original stanza");
		end);
	end);

	describe("#error_reply()", function()
		it("should work for <s>", function()
			-- Test stanza
			local s = st.stanza("s", { to = "touser", from = "fromuser", id = "123" })
				:tag("child1");
			-- Make reply stanza
			local r = st.error_reply(s, "cancel", "service-unavailable");
			assert.are.equal(r.name, s.name);
			assert.are.equal(r.id, s.id);
			assert.are.equal(r.attr.to, s.attr.from);
			assert.are.equal(r.attr.from, s.attr.to);
			assert.are.equal(#r.tags, 1);
			assert.are.equal(r.tags[1].tags[1].name, "service-unavailable");
		end);

		it("should work for <iq get>", function()
			-- Test stanza
			local s = st.stanza("iq", { to = "touser", from = "fromuser", id = "123", type = "get" })
				:tag("child1");
			-- Make reply stanza
			local r = st.error_reply(s, "cancel", "service-unavailable");
			assert.are.equal(r.name, s.name);
			assert.are.equal(r.id, s.id);
			assert.are.equal(r.attr.to, s.attr.from);
			assert.are.equal(r.attr.from, s.attr.to);
			assert.are.equal(r.attr.type, "error");
			assert.are.equal(#r.tags, 1);
			assert.are.equal(r.tags[1].tags[1].name, "service-unavailable");
		end);
	end);

	describe("should reject #invalid", function ()
		local invalid_names = {
			["empty string"] = "", ["characters"] = "<>";
		}
		local invalid_data = {
			["number"] = 1234, ["table"] = {};
			["utf8"] = string.char(0xF4, 0x90, 0x80, 0x80);
			["nil"] = "nil"; ["boolean"] = true;
		};

		for value_type, value in pairs(invalid_names) do
			it(value_type.." in tag names", function ()
				assert.error_matches(function ()
					st.stanza(value);
				end, value_type);
			end);
			it(value_type.." in attribute names", function ()
				assert.error_matches(function ()
					st.stanza("valid", { [value] = "valid" });
				end, value_type);
			end);
		end
		for value_type, value in pairs(invalid_data) do
			if value == "nil" then value = nil; end
			it(value_type.." in tag names", function ()
				assert.error_matches(function ()
					st.stanza(value);
				end, value_type);
			end);
			it(value_type.." in attribute names", function ()
				assert.error_matches(function ()
					st.stanza("valid", { [value] = "valid" });
				end, value_type);
			end);
			if value ~= nil then
				it(value_type.." in attribute values", function ()
					assert.error_matches(function ()
						st.stanza("valid", { valid = value });
					end, value_type);
				end);
				it(value_type.." in text node", function ()
					assert.error_matches(function ()
						st.stanza("valid"):text(value);
					end, value_type);
				end);
			end
		end
	end);

	describe("#is_stanza", function ()
		-- is_stanza(any) -> boolean
		it("identifies stanzas as stanzas", function ()
			assert.truthy(st.is_stanza(st.stanza("x")));
		end);
		it("identifies strings as not stanzas", function ()
			assert.falsy(st.is_stanza(""));
		end);
		it("identifies numbers as not stanzas", function ()
			assert.falsy(st.is_stanza(1));
		end);
		it("identifies tables as not stanzas", function ()
			assert.falsy(st.is_stanza({}));
		end);
	end);

	describe("#remove_children", function ()
		it("should work", function ()
			local s = st.stanza("x", {xmlns="test"})
				:tag("y", {xmlns="test"}):up()
				:tag("z", {xmlns="test2"}):up()
				:tag("x", {xmlns="test2"}):up()

			s:remove_children("x");
			assert.falsy(s:get_child("x"))
			assert.truthy(s:get_child("z","test2"));
			assert.truthy(s:get_child("x","test2"));

			s:remove_children(nil, "test2");
			assert.truthy(s:get_child("y"))
			assert.falsy(s:get_child(nil,"test2"));

			s:remove_children();
			assert.falsy(s.tags[1]);
		end);
	end);

	describe("#maptags", function ()
		it("should work", function ()
			local s = st.stanza("test")
				:tag("one"):up()
				:tag("two"):up()
				:tag("one"):up()
				:tag("three"):up();

			local function one_filter(tag)
				if tag.name == "one" then
					return nil;
				end
				return tag;
			end
			assert.equal(4, #s.tags);
			s:maptags(one_filter);
			assert.equal(2, #s.tags);
		end);

		it("should work with multiple consecutive text nodes", function ()
			local s = st.deserialize({
				"\n";
				{
					"away";
					name = "show";
					attr = {};
				};
				"\n";
				{
					"I am away";
					name = "status";
					attr = {};
				};
				"\n";
				{
					"0";
					name = "priority";
					attr = {};
				};
				"\n";
				{
					name = "c";
					attr = {
						xmlns = "http://jabber.org/protocol/caps";
						node = "http://psi-im.org";
						hash = "sha-1";
					};
				};
				"\n";
				"\n";
				name = "presence";
				attr = {
					to = "user@example.com/jflsjfld";
					from = "room@chat.example.org/nick";
				};
			});

			assert.equal(4, #s.tags);

			s:maptags(function (tag) return tag; end);
			assert.equal(4, #s.tags);

			s:maptags(function (tag)
				if tag.name == "c" then
					return nil;
				end
				return tag;
			end);
			assert.equal(3, #s.tags);
		end);
		it("errors on invalid data - #981", function ()
			local s = st.message({}, "Hello");
			s.tags[1] = st.clone(s.tags[1]);
			assert.has_error_match(function ()
				s:maptags(function () end);
			end, "Invalid stanza");
		end);
	end);
end);
