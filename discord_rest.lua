--- Discord REST API interface
-- @classmod DiscordRest

-- Discord API base URL
local discordApi = "https://discord.com/api"

-- Discord REST API endpoint URIs
local endpoints = {
	["channel"]      = "/channels/%s",
	["message"]      = "/channels/%s/messages/%s",
	["messages"]     = "/channels/%s/messages",
	["ownReaction"]  = "/channels/%s/messages/%s/reactions/%s/@me",
	["reactions"]    = "/channels/%s/messages/%s/reactions/%s",
	["userReaction"] = "/channels/%s/messages/%s/reactions/%s/%s",
	["user"]         = "/users/%s",
}

-- Check if an HTTP status code indicates an error
local function isResponseError(status)
	return status < 200 or status > 299
end

-- Check if an HTTP status code indicates success
local function isResponseSuccess(status)
	return not isResponseError(status)
end

-- Create a simple PerformHttpRequest callback that resolves or rejects a promise
function createSimplePromiseCallback(p)
	return function(status, data, headers)
		if isResponseSuccess(status) then
			p:resolve(json.decode(data))
		else
			p:reject(status)
		end
	end
end

-- Combine options into query string
function createQueryString(options)
	local params = {}

	if options then
		for k, v in pairs(options) do
			table.insert(params, ("%s=%s"):format(k, v))
		end
	end

	if #params > 0 then
		return "?" .. table.concat(params, "&")
	else
		return ""
	end
end

-- Format an API endpoint URI
local function formatEndpoint(name, variables, parameters)
	if type(variables) == "table" then
		return discordApi .. endpoints[name]:format(table.unpack(variables)) .. createQueryString(parameters)
	else
		return discordApi .. endpoints[name]:format(variables) .. createQueryString(parameters)
	end
end

--- Discord REST API interface
-- @type DiscordRest
DiscordRest = {}

--- Create a new Discord REST API interface
-- @param botToken Optional bot token to use for authorization
-- @return A new Discord REST API interface object
-- @usage local discord = DiscordRest:new("[bot token]")
function DiscordRest:new(botToken)
	self.__index = self
	local self = setmetatable({}, self)

	self.botToken = botToken

	self.queue = {}
	self.rateLimitRemaining = 0
	self.rateLimitReset = 0

	Citizen.CreateThread(function()
		while self do
			self:processQueue()
			Citizen.Wait(500)
		end
	end)

	return self
end

-- Add a message to the queue
function DiscordRest:enqueue(cb)
	table.insert(self.queue, 1, cb)
end

-- Remove a message from the queue
function DiscordRest:dequeue()
	local cb = table.remove(self.queue)

	if cb then
		cb()
	end
end

-- Process message while respecting the rate limit
function DiscordRest:processQueue()
	if self.rateLimitRemaining > 0 or os.time() > self.rateLimitReset then
		self:dequeue()
	end
end

-- Handle HTTP responses from the Discord REST API
function DiscordRest:handleResponse(status, text, headers, callback)
	if isResponseError(status) then
		if status == 429 then
			self.rateLimitRemaining = 0
			self.rateLimitReset = os.time() + 5
		end

		print(("Discord REST API error: %d"):format(status, text or "", json.encode(headers)))
	else
		local rateLimitRemaining = tonumber(headers["x-ratelimit-remaining"])
		local rateLimitReset = tonumber(headers["x-ratelimit-reset"])

		if rateLimitRemaining then
			self.rateLimitRemaining = rateLimitRemaining
		end

		if rateLimitReset then
			self.rateLimitReset = rateLimitReset
		end
	end

	if callback then
		callback(status, text, headers)
	end
end

-- Get the bot authorization string
function DiscordRest:getAuthorization(botToken)
	return "Bot " .. (botToken or self.botToken or "")
end

--- Perform a custom HTTP request to the Discord REST API, while still respecting the rate limit.
-- @param url The endpoint of the API to request.
-- @param callback An optional callback function to execute when the response is received.
-- @param method The HTTP method of the request.
-- @param data Data to send in the body of the request.
-- @param headers The HTTP headers of the request.
-- @usage discord:performHttpRequest("https://discord.com/api/channels/[channel ID]/messages/[message ID]", nil, "DELETE", "", {["Authorization"] = "Bot [bot token]"})
-- @see https://docs.fivem.net/docs/scripting-reference/runtimes/lua/functions/PerformHttpRequest/
function DiscordRest:performHttpRequest(url, callback, method, data, headers)
	self:enqueue(function()
		PerformHttpRequest(url,
			function(status, text, headers)
				self:handleResponse(status, text, headers, callback)
			end,
			method, data, headers)
	end)
end

-- Perform an authorized request to the REST API
function DiscordRest:performAuthorizedRequest(url, method, data, botToken)
	local p = promise.new()

	local authorization = self:getAuthorization(botToken)

	local headers = {
		["Authorization"] = authorization
	}

	if data then
		headers["Content-Type"] = "application/json"

		if type(data) ~= "string" then
			data = json.encode(data)
		end
	else
		headers["Content-Length"] = "0"
		data = ""
	end

	self:performHttpRequest(url, createSimplePromiseCallback(p), method, data, headers)

	return p
end

--- Channel
-- @section channel

--- Post a message.
-- @param channelId The ID of the channel to post in.
-- @param message The message parameters.
-- @param botToken Optional bot token to use for authorization.
-- @return A new promise which is resolved when the message is posted.
-- @usage discord:createMessage("[channel ID]", {content = "Hello, world!"})
-- @see https://discord.com/developers/docs/resources/channel#create-message
function DiscordRest:createMessage(channelId, message, botToken)
	return self:performAuthorizedRequest(formatEndpoint("messages", {channelId}), "POST", message, botToken)
end

--- Create a reaction for a message.
-- @param channelId The ID of the channel containing the message.
-- @param messageId The ID of the message to add a reaction to.
-- @param emoji The emoji to react with.
-- @param botToken Optional bot token to use for authorization.
-- @return A new promise which is resolved when the reaction is added to the message.
-- @usage discord:createReaction("[channel ID]", "[message ID]", "💗")
-- @see https://discord.com/developers/docs/resources/channel#create-reaction
function DiscordRest:createReaction(channelId, messageId, emoji, botToken)
	return self:performAuthorizedRequest(formatEndpoint("ownReaction", {channelId, messageId, emoji}), "PUT", nil, botToken)
end

--- Delete a channel.
-- @param channelId The ID of the channel.
-- @param botToken Optional bot token to use for authorization.
-- @return A new promise.
-- @usage discord:deleteChannel("[channel ID]")
-- @see https://discord.com/developers/docs/resources/channel#deleteclose-channel
function DiscordRest:deleteChannel(channelId, botToken)
	return self:performAuthorizedRequest(formatEndpoint("channel", {channelId}), "DELETE", nil, botToken)
end

--- Delete a message from a channel.
-- @param channelId The ID of the channel.
-- @param messageId The ID of the message.
-- @param botToken Optional bot token to use for authorization.
-- @return A new promise.
-- @usage discord:deleteMessage("[channel ID]", "[message ID]")
-- @see https://discord.com/developers/docs/resources/channel#delete-message
function DiscordRest:deleteMessage(channelId, messageId, botToken)
	return self:performAuthorizedRequest(formatEndpoint("message", {channelId, messageId}), "DELETE", nil, botToken)
end

--- Remove own reaction from a message.
-- @param channelId The ID of the channel containing the message.
-- @param messageId The ID of the message to remove the reaction from.
-- @param emoji The emoji of the reaction to remove.
-- @param botToken Optional bot token to use for authorization.
-- @return A new promise.
-- @usage discord:deleteOwnReaction("[channel ID]", "[message ID]", "💗")
-- @see https://discord.com/developers/docs/resources/channel#delete-own-reaction
function DiscordRest:deleteOwnReaction(channelId, messageId, emoji, botToken)
	return self:performAuthorizedRequest(formatEndpoint("ownReaction", {channelId, messageId, emoji}), "DELETE", nil, botToken)
end

--- Remove a user's reaction from a message.
-- @param channelId The ID of the channel containing the message.
-- @param messageId The message to remove the reaction from.
-- @param emoji The emoji of the reaction to remove.
-- @param userId The ID of the user whose reaction will be removed.
-- @param botToken Optional bot token to use for authorization.
-- @return A new promise.
-- @usage discord:deleteUserReaction("[channel ID]", "[message ID]", "💗", "[user ID]")
-- @see https://discord.com/developers/docs/resources/channel#delete-user-reaction
function DiscordRest:deleteUserReaction(channelId, messageId, emoji, userId, botToken)
	return self:performAuthorizedRequest(formatEndpoint("userReaction", {channelId, messageId, emoji, userId}), "DELETE", nil, botToken)
end

--- Edit a previously sent message.
-- @param channelId The ID of the channel containing the message.
-- @param messageId The ID of the message to edit.
-- @param message The edited message.
-- @param botToken Optional bot token to use for authorization.
-- @return A new promise, which resolves with the edited message when the request is completed.
-- @usage discord:editMessage("[channel ID]", "[message ID]", {content = "I edited this message!"})
-- @see https://discord.com/developers/docs/resources/channel#edit-message
function DiscordRest:editMessage(channelId, messageId, message, botToken)
	return self:performAuthorizedRequest(formatEndpoint("message", {channelId, messageId}), "PATCH", message, botToken)
end

--- Get channel information.
-- @param channelId The ID of the channel.
-- @param botToken Optional bot token to use for authorization.
-- @return A new promise.
-- @usage discord:getChannel("[channel ID]"):next(function(channel) ... end)
-- @see https://discord.com/developers/docs/resources/channel#get-channel
function DiscordRest:getChannel(channelId, botToken)
	return self:performAuthorizedRequest(formatEndpoint("channel", {channelId}), "GET", nil, botToken)
end

--- Get a specific message from a channel.
-- @param channelId The ID of the channel.
-- @param messageId The ID of the message.
-- @param botToken Optional bot token to use for authorization.
-- @return A new promise.
-- @usage discord:getChannelMessage("[channel ID]", "[messageId]")
-- @see https://discord.com/developers/docs/resources/channel#get-channel-message
function DiscordRest:getChannelMessage(channelId, messageId, botToken)
	return self:performAuthorizedRequest(formatEndpoint("message", {channelId, messageId}), "GET", nil, botToken)
end

--- Get a list of messages from a channels
-- @param channelId The ID of the channel.
-- @param options Options to tailor the query.
-- @param botToken Optional bot token to use for authorization.
-- @return A new promise.
-- @usage discord:getChannelMessage("[channel ID]", {limit = 1}):next(function(messages) ... end)
-- @see https://discord.com/developers/docs/resources/channel#get-channel-messages
function DiscordRest:getChannelMessages(channelId, options, botToken)
	return self:performAuthorizedRequest(formatEndpoint("messages", {channelId}, options), "GET", nil, botToken)
end

--- Get a list of users that reacted to a message with a specific emoji.
-- @param channelId The ID of the channel containing the message.
-- @param messageId The ID of the message to get reactions from.
-- @param emoji The emoji of the reaction.
-- @param options Options to tailor the query.
-- @param botToken Optional bot token to use for authorization.
-- @return A new promise.
-- @usage discord:getReactions("[channel ID]", "[message ID]", "💗"):next(function(users) ... end)
-- @see https://discord.com/developers/docs/resources/channel#get-reactions
function DiscordRest:getReactions(channelId, messageId, emoji, options, botToken)
	return self:performAuthorizedRequest(formatEndpoint("reactions", {channelId, messageId, emoji}, options), "GET", nil, botToken)
end

--- Update a channel's settings.
-- @param channelId The ID of the channel.
-- @param channel The new channel settings.
-- @param botToken Optional bot token to use for authorization.
-- @return A new promise.
-- @usage discord:modifyChannel("[channel ID]", {name = "new-name"})
-- @see https://discord.com/developers/docs/resources/channel#modify-channel
function DiscordRest:modifyChannel(channelId, channel, botToken)
	return self:performAuthorizedRequest(formatEndpoint("channel", channelId), "PATCH", channel, botToken)
end

--- User
-- @section user

--- Get user information.
-- @param userId The ID of the user.
-- @param botToken Optional bot token to use for authorization.
-- @return A new promise.
-- @usage discord:getUser("[user ID]"):next(function(user) ... end)
-- @see https://discord.com/developers/docs/resources/user#get-user
function DiscordRest:getUser(userId, botToken)
	return self:performAuthorizedRequest(formatEndpoint("user", {userId}), "GET", nil, botToken)
end

--- Webhook
-- @section webhook

--- Execute a Discord webhook
-- @param url The webhook URL.
-- @param data The data to send.
-- @return A new promise.
-- @usage discord:executeWebhook("https://discord.com/api/webhooks/[webhook ID]/[webhook token]", {content = "Hello, world!"})
-- @see https://discord.com/developers/docs/resources/webhook#execute-webhook
function DiscordRest:executeWebhook(url, data)
	local p = promise.new()
	self:performHttpRequest(url, createSimplePromiseCallback(p), "POST", json.encode(data), {["Content-Type"] = "application/json"})
	return p
end
