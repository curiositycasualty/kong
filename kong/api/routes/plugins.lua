local cjson = require "cjson"
local reports = require "kong.reports"
local endpoints = require "kong.api.endpoints"
local arguments = require "kong.api.arguments"
local api_helpers = require "kong.api.api_helpers"
local cycle_aware_deep_copy = require("kong.tools.table").cycle_aware_deep_copy


local ngx = ngx
local kong = kong
local type = type
local find = string.find
local pairs = pairs
local lower = string.lower
local setmetatable = setmetatable


local function reports_timer(premature, data)
  if premature then
    return
  end

  local r_data = cycle_aware_deep_copy(data)

  r_data.config = nil
  r_data.route = nil
  r_data.service = nil
  r_data.consumer = nil
  r_data.enabled = nil

  if type(data.service) == "table" and data.service.id then
    r_data.e = "s"

  elseif type(data.route) == "table" and data.route.id then
    r_data.e = "r"

  elseif type(data.consumer) == "table" and data.consumer.id then
    r_data.e = "c"
  end

  if data.name == "ai-proxy" then
    r_data.config = {
      llm = {
        model = {}
      }
    }

    r_data.config.llm.model.name = data.config.model.name
    r_data.config.llm.model.provider = data.config.model.provider

  elseif data.name == "ai-request-transformer" or data.name == "ai-response-transformer" then
    r_data.config = {
      llm = {
        model = {}
      }
    }

    r_data.config.llm.model.name = data.config.llm.model.name
    r_data.config.llm.model.provider = data.config.llm.model.provider
  end

  reports.send("api", r_data)
end


local function post_process(data)
  ngx.timer.at(0, reports_timer, data)
  return data
end


local function post_plugin(_, _, _, parent)
  return parent(post_process)
end


local function patch_plugin(self, db, _, parent)
  local post = self.args and self.args.post
  if post then
    -- Read-before-write only if necessary
    if post.name == nil then
      -- We need the name, otherwise we don't know what type of
      -- plugin this is and we can't perform *any* validations.
      local plugin, _, err_t = endpoints.select_entity(self, db, db.plugins.schema)
      if err_t then
        return endpoints.handle_error(err_t)
      end

      if not plugin then
        return kong.response.exit(404, { message = "Not found" })
      end

      post.name = plugin.name
    end

    -- Only now we can decode the 'config' table for form-encoded values
    local content_type = ngx.var.content_type
    if content_type then
      content_type = lower(content_type)
      if find(content_type, "application/x-www-form-urlencoded", 1, true) == 1 or
         find(content_type, "multipart/form-data",               1, true) == 1 then
        post = arguments.decode(post, kong.db.plugins.schema)
      end
    end

    self.args.post = post
  end

  return parent()
end


return {
  ["/plugins"] = {
    POST = post_plugin,
  },

  ["/plugins/:plugins"] = {
    PATCH = patch_plugin
  },

  ["/plugins/schema/:name"] = {
    GET = function(self, db)
      kong.log.deprecation("/plugins/schema/:name endpoint is deprecated, ",
                           "please use /schemas/plugins/:name instead", {
                             after = "1.2.0",
                             removal = "4.0.0",
                           })
      local subschema = db.plugins.schema.subschemas[self.params.name]
      if not subschema then
        return kong.response.exit(404, { message = "No plugin named '" .. self.params.name .. "'" })
      end

      local copy = api_helpers.schema_to_jsonable(subschema.fields.config)
      return kong.response.exit(200, copy)
    end
  },

  ["/plugins/enabled"] = {
    GET = function()
      local enabled_plugins = setmetatable({}, cjson.array_mt)
      for k in pairs(kong.configuration.loaded_plugins) do
        enabled_plugins[#enabled_plugins+1] = k
      end
      return kong.response.exit(200, {
        enabled_plugins = enabled_plugins
      })
    end
  },

  ["/consumers/:consumers/plugins/:plugins"] = {
    PATCH = patch_plugin,
  },

  ["/routes/:routes/plugins/:plugins"] = {
    PATCH = patch_plugin,
  },

  ["/services/:services/plugins"] = {
    POST = post_plugin,
  },

  ["/routes/:routes/plugins"] = {
    POST = post_plugin,
  },

  ["/consumers/:consumers/plugins"] = {
    POST = post_plugin,
  },

  ["/services/:services/plugins/:plugins"] = {
    PATCH = patch_plugin,
  },
}
