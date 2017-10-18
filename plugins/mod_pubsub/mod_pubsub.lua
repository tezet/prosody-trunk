local pubsub = require "util.pubsub";
local st = require "util.stanza";
local jid_bare = require "util.jid".bare;
local usermanager = require "core.usermanager";

local xmlns_pubsub = "http://jabber.org/protocol/pubsub";
local xmlns_pubsub_event = "http://jabber.org/protocol/pubsub#event";
local xmlns_pubsub_owner = "http://jabber.org/protocol/pubsub#owner";

local autocreate_on_publish = module:get_option_boolean("autocreate_on_publish", false);
local autocreate_on_subscribe = module:get_option_boolean("autocreate_on_subscribe", false);
local pubsub_disco_name = module:get_option_string("name", "Prosody PubSub Service");
local expose_publisher = module:get_option_boolean("expose_publisher", false)

local enable_persistence = module:get_option_boolean("experimental_pubsub_item_persistence", false);

local service;

local lib_pubsub = module:require "pubsub";

module:depends("disco");
module:add_identity("pubsub", "service", pubsub_disco_name);
module:add_feature("http://jabber.org/protocol/pubsub");

function handle_pubsub_iq(event)
	return lib_pubsub.handle_pubsub_iq(event, service);
end

local function simple_itemstore(config, node)
	local archive = module:open_store("pubsub_"..node, "archive");
	return lib_pubsub.archive_itemstore(archive, config, nil, node);
end

if enable_persistence then
	module:log("warn", "Item persistence is an experimental feature. Note that ownership information is lost on restart.")
else
	simple_itemstore = nil;
end


function simple_broadcast(kind, node, jids, item, actor)
	if item then
		item = st.clone(item);
		item.attr.xmlns = nil; -- Clear the pubsub namespace
		if expose_publisher and actor then
			item.attr.publisher = actor
		end
	end
	local message = st.message({ from = module.host, type = "headline" })
		:tag("event", { xmlns = xmlns_pubsub_event })
			:tag(kind, { node = node })
				:add_child(item);
	for jid in pairs(jids) do
		module:log("debug", "Sending notification to %s", jid);
		message.attr.to = jid;
		module:send(message);
	end
end

module:hook("iq/host/"..xmlns_pubsub..":pubsub", handle_pubsub_iq);
module:hook("iq/host/"..xmlns_pubsub_owner..":pubsub", handle_pubsub_iq);

local function add_disco_features_from_service(service)
	for feature in lib_pubsub.get_feature_set(service) do
		module:add_feature(xmlns_pubsub.."#"..feature);
	end
end

module:hook("host-disco-info-node", function (event)
	local stanza, reply, node = event.stanza, event.reply, event.node;
	local ok, ret = service:get_nodes(stanza.attr.from);
	if not ok or not ret[node] then
		return;
	end
	event.exists = true;
	reply:tag("identity", { category = "pubsub", type = "leaf" });
end);

module:hook("host-disco-items-node", function (event)
	local stanza, reply, node = event.stanza, event.reply, event.node;
	local ok, ret = service:get_items(node, stanza.attr.from);
	if not ok then
		return;
	end

	for _, id in ipairs(ret) do
		reply:tag("item", { jid = module.host, name = id }):up();
	end
	event.exists = true;
end);


module:hook("host-disco-items", function (event)
	local stanza, reply = event.stanza, event.reply;
	local ok, ret = service:get_nodes(stanza.attr.from);
	if not ok then
		return;
	end
	for node, node_obj in pairs(ret) do
		reply:tag("item", { jid = module.host, node = node, name = node_obj.config.name }):up();
	end
end);

local admin_aff = module:get_option_string("default_admin_affiliation", "owner");
local function get_affiliation(jid)
	local bare_jid = jid_bare(jid);
	if bare_jid == module.host or usermanager.is_admin(bare_jid, module.host) then
		return admin_aff;
	end
end

function set_service(new_service)
	service = new_service;
	module.environment.service = service;
	add_disco_features_from_service(service);
end

function module.save()
	return { service = service };
end

function module.restore(data)
	set_service(data.service);
end

function module.load()
	if module.reloading then return; end

	set_service(pubsub.new({
		capabilities = {
			none = {
				create = false;
				publish = false;
				retract = false;
				get_nodes = true;

				subscribe = true;
				unsubscribe = true;
				get_subscription = true;
				get_subscriptions = true;
				get_items = true;

				subscribe_other = false;
				unsubscribe_other = false;
				get_subscription_other = false;
				get_subscriptions_other = false;

				be_subscribed = true;
				be_unsubscribed = true;

				set_affiliation = false;
			};
			publisher = {
				create = false;
				publish = true;
				retract = true;
				get_nodes = true;

				subscribe = true;
				unsubscribe = true;
				get_subscription = true;
				get_subscriptions = true;
				get_items = true;

				subscribe_other = false;
				unsubscribe_other = false;
				get_subscription_other = false;
				get_subscriptions_other = false;

				be_subscribed = true;
				be_unsubscribed = true;

				set_affiliation = false;
			};
			owner = {
				create = true;
				publish = true;
				retract = true;
				delete = true;
				get_nodes = true;
				configure = true;

				subscribe = true;
				unsubscribe = true;
				get_subscription = true;
				get_subscriptions = true;
				get_items = true;


				subscribe_other = true;
				unsubscribe_other = true;
				get_subscription_other = true;
				get_subscriptions_other = true;

				be_subscribed = true;
				be_unsubscribed = true;

				set_affiliation = true;
			};
		};

		autocreate_on_publish = autocreate_on_publish;
		autocreate_on_subscribe = autocreate_on_subscribe;

		itemstore = simple_itemstore;
		broadcaster = simple_broadcast;
		get_affiliation = get_affiliation;

		normalize_jid = jid_bare;
	}));
end
