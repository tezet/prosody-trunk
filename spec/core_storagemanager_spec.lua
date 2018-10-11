local server = require "net.server_select";
package.loaded["net.server"] = server;

local st = require "util.stanza";

local function mock_prosody()
	_G.prosody = {
		core_post_stanza = function () end;
		events = require "util.events".new();
		hosts = {};
		paths = {
			data = "./data";
		};
	};
end

local configs = {
	internal = {
		storage = "internal";
	};
	sqlite = {
		storage = "sql";
		sql = { driver = "SQLite3", database = "prosody-tests.sqlite" };
	};
	mysql = {
		storage = "sql";
		sql = { driver = "MySQL",  database = "prosody", username = "prosody", password = "secret", host = "localhost" };
	};
	postgres = {
		storage = "sql";
		sql = { driver = "PostgreSQL", database = "prosody", username = "prosody", password = "secret", host = "localhost" };
	};
};

local test_host = "storage-unit-tests.invalid";

describe("storagemanager", function ()
	for backend, backend_config in pairs(configs) do
		local tagged_name = "#"..backend;
		if backend ~= backend_config.storage then
			tagged_name = tagged_name.." #"..backend_config.storage;
		end
		insulate(tagged_name.." #storage backend", function ()
			mock_prosody();

			local config = require "core.configmanager";
			local sm = require "core.storagemanager";
			local hm = require "core.hostmanager";
			local mm = require "core.modulemanager";

			-- Simple check to ensure insulation is working correctly
			assert.is_nil(config.get(test_host, "storage"));

			for k, v in pairs(backend_config) do
				config.set(test_host, k, v);
			end
			assert(hm.activate(test_host, {}));
			sm.initialize_host(test_host);
			assert(mm.load(test_host, "storage_"..backend_config.storage));

			describe("key-value stores", function ()
				-- These tests rely on being executed in order, disable any order
				-- randomization for this block
				randomize(false);

				local store;
				it("may be opened", function ()
					store = assert(sm.open(test_host, "test"));
				end);

				local simple_data = { foo = "bar" };

				it("may set data for a user", function ()
					assert(store:set("user9999", simple_data));
				end);

				it("may get data for a user", function ()
					assert.same(simple_data, assert(store:get("user9999")));
				end);

				it("may remove data for a user", function ()
					assert(store:set("user9999", nil));
					local ret, err = store:get("user9999");
					assert.is_nil(ret);
					assert.is_nil(err);
				end);
			end);

			describe("archive stores", function ()
				randomize(false);

				local archive;
				it("can be opened", function ()
					archive = assert(sm.open(test_host, "test-archive", "archive"));
				end);

				local test_stanza = st.stanza("test", { xmlns = "urn:example:foo" })
					:tag("foo"):up()
					:tag("foo"):up();
				local test_time = 1539204123;

				local test_data = {
					{ nil, test_stanza, test_time, "contact@example.com" };
					{ nil, test_stanza, test_time+1, "contact2@example.com" };
					{ nil, test_stanza, test_time+2, "contact2@example.com" };
					{ nil, test_stanza, test_time-1, "contact2@example.com" };
				};

				it("can be added to", function ()
					for _, data_item in ipairs(test_data) do
						local ok = archive:append("user", unpack(data_item, 1, 4));
						assert.truthy(ok);
					end
				end);

				describe("can be queried", function ()
					it("for all items", function ()
						local data, err = archive:find("user", {});
						assert.truthy(data);
						local count = 0;
						for id, item, when in data do
							count = count + 1;
							assert.truthy(id);
							assert(st.is_stanza(item));
							assert.equal("test", item.name);
							assert.equal("urn:example:foo", item.attr.xmlns);
							assert.equal(2, #item.tags);
							assert.equal(test_data[count][3], when);
						end
						assert.equal(#test_data, count);
					end);

					it("by JID", function ()
						local data, err = archive:find("user", {
							with = "contact@example.com";
						});
						assert.truthy(data);
						local count = 0;
						for id, item, when in data do
							count = count + 1;
							assert.truthy(id);
							assert(st.is_stanza(item));
							assert.equal("test", item.name);
							assert.equal("urn:example:foo", item.attr.xmlns);
							assert.equal(2, #item.tags);
							assert.equal(test_time, when);
						end
						assert.equal(1, count);
					end);

					it("by time (end)", function ()
						local data, err = archive:find("user", {
							["end"] = test_time;
						});
						assert.truthy(data);
						local count = 0;
						for id, item, when in data do
							count = count + 1;
							assert.truthy(id);
							assert(st.is_stanza(item));
							assert.equal("test", item.name);
							assert.equal("urn:example:foo", item.attr.xmlns);
							assert.equal(2, #item.tags);
							assert(test_time >= when);
						end
						assert.equal(2, count);
					end);

					it("by time (start)", function ()
						local data, err = archive:find("user", {
							["start"] = test_time;
						});
						assert.truthy(data);
						local count = 0;
						for id, item, when in data do
							count = count + 1;
							assert.truthy(id);
							assert(st.is_stanza(item));
							assert.equal("test", item.name);
							assert.equal("urn:example:foo", item.attr.xmlns);
							assert.equal(2, #item.tags);
							assert(test_time <= when);
						end
						assert.equal(#test_data -1, count);
					end);

					it("by time (start+end)", function ()
						local data, err = archive:find("user", {
							["start"] = test_time;
							["end"] = test_time+1;
						});
						assert.truthy(data);
						local count = 0;
						for id, item, when in data do
							count = count + 1;
							assert.truthy(id);
							assert(st.is_stanza(item));
							assert.equal("test", item.name);
							assert.equal("urn:example:foo", item.attr.xmlns);
							assert.equal(2, #item.tags);
							assert(when >= test_time, ("%d >= %d"):format(when, test_time));
							assert(when <= test_time+1, ("%d <= %d"):format(when, test_time+1));
						end
						assert.equal(2, count);
					end);
				end);

				it("can selectively delete items", function ()
					local delete_id;
					do
						local data = assert(archive:find("user", {}));
						local count = 0;
						for id, item, when in data do --luacheck: ignore 213/item 213/when
							count = count + 1;
							if count == 2 then
								delete_id = id;
							end
							assert.truthy(id);
						end
						assert.equal(#test_data, count);
					end

					assert(archive:delete("user", { key = delete_id }));

					do
						local data = assert(archive:find("user", {}));
						local count = 0;
						for id, item, when in data do --luacheck: ignore 213/item 213/when
							count = count + 1;
							assert.truthy(id);
							assert.not_equal(delete_id, id);
						end
						assert.equal(#test_data-1, count);
					end
				end);

				it("can be purged", function ()
					local ok, err = archive:delete("user");
					assert.truthy(ok);
					local data, err = archive:find("user", {
						with = "contact@example.com";
					});
					assert.truthy(data);
					local count = 0;
					for id, item, when in data do -- luacheck: ignore id item when
						count = count + 1;
					end
					assert.equal(0, count);
				end);

				it("can truncate the oldest items", function ()
					local username = "user-truncate";
					for i = 1, 10 do
						assert(archive:append(username, nil, test_stanza, i, "contact@example.com"));
					end
					assert(archive:delete(username, { truncate = 3 }));

					do
						local data = assert(archive:find(username, {}));
						local count = 0;
						for id, item, when in data do --luacheck: ignore 213/when
							count = count + 1;
							assert.truthy(id);
							assert(st.is_stanza(item));
							assert(when > 7, ("%d > 7"):format(when));
						end
						assert.equal(3, count);
					end
				end);

				it("overwrites existing keys with new data", function ()
					local prefix = ("a"):rep(50);
					local username = "user-overwrite";
					assert(archive:append(username, prefix.."-1", test_stanza, test_time, "contact@example.com"));
					assert(archive:append(username, prefix.."-2", test_stanza, test_time, "contact@example.com"));

					do
						local data = assert(archive:find(username, {}));
						local count = 0;
						for id, item, when in data do --luacheck: ignore 213/when
							count = count + 1;
							assert.truthy(id);
							assert.equals(("%s-%d"):format(prefix, count), id);
							assert(st.is_stanza(item));
						end
						assert.equal(2, count);
					end

					local new_stanza = st.clone(test_stanza);
					new_stanza.attr.foo = "bar";
					assert(archive:append(username, prefix.."-2", new_stanza, test_time+1, "contact2@example.com"));

					do
						local data = assert(archive:find(username, {}));
						local count = 0;
						for id, item, when in data do
							count = count + 1;
							assert.truthy(id);
							assert.equals(("%s-%d"):format(prefix, count), id);
							assert(st.is_stanza(item));
							if count == 2 then
								assert.equals(test_time+1, when);
								assert.equals("bar", item.attr.foo);
							end
						end
						assert.equal(2, count);
					end
				end);

				it("can contain multiple long unique keys #issue1073", function ()
					local prefix = ("a"):rep(50);
					assert(archive:append("user-issue1073", prefix.."-1", test_stanza, test_time, "contact@example.com"));
					assert(archive:append("user-issue1073", prefix.."-2", test_stanza, test_time, "contact@example.com"));

					local data = assert(archive:find("user-issue1073", {}));
					local count = 0;
					for id, item, when in data do --luacheck: ignore 213/when
						print(id)
						count = count + 1;
						assert.truthy(id);
						assert(st.is_stanza(item));
					end
					assert.equal(2, count);
					assert(archive:delete("user-issue1073"));
				end);
			end);
		end);
	end
end);
