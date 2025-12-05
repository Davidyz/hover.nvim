local api = vim.api
local lsp = vim.lsp

if lsp.inlay_hint.apply_action == nil then
  -- we want to use `vim.lsp.inlay_hint.apply_action` to avoid re-implementing `inlayHint/resolve`
  return
end

--- @type table<integer, Hover.Provider?> -- client_id -> provider_id
local lsp_providers = {}

--- @class InlayHintProvider
--- @field client_id integer
local InlayHintProvider = {}
InlayHintProvider.__index = InlayHintProvider

function InlayHintProvider:new(client_id)
  return setmetatable({ client_id = client_id }, self)
end

--- @param bufnr integer
--- @return boolean
function InlayHintProvider:enabled(bufnr)
  local client =
    lsp.get_clients({ id = self.client_id, bufnr = bufnr, method = 'textDocument/hover' })[1]
  return (client and lsp_providers[client.id]) ~= nil
end

--- @param params Hover.Provider.Params
--- @param done fun(result? :false|Hover.Provider.Result)
function InlayHintProvider:execute(params, done)
  local bufnr = params.bufnr
  local row0 = params.pos[1] - 1
  local col0 = params.pos[2]

  lsp.inlay_hint.apply_action(function(hints, ctx, on_finish)
    if #hints == 0 then
      return 0
    end

    ---@type lsp.InlayHint?
    local hint
    for _, h in pairs(hints) do
      if
        type(h.label) == 'table'
        and #h.label > 0
        and vim.iter(h.label):any(
          ---@param label lsp.InlayHintLabelPart
          function(label)
            return label.location ~= nil
          end
        )
      then
        -- fetch the first inlay hint that comes with labelparts that have locations.
        hint = h
        break
      end
    end
    if hint == nil then
      return 0
    end
    ---@type lsp.InlayHintLabelPart[]
    local labels = vim
      .iter(hint.label)
      :filter(
        ---@param label lsp.InlayHintLabelPart
        function(label)
          return label.location ~= nil
        end
      )
      :totable()
    if #labels == 0 then
      return 0
    end

    local lines = {}

    ---@param idx? integer
    ---@param label? lsp.InlayHintLabelPart
    local function fetch_hover(idx, label)
      if idx == nil or label == nil then
        if #lines == 0 then
          lines = { 'Empty' }
        end
        local tmp_buf

        vim.schedule(function()
          tmp_buf = api.nvim_create_buf(false, true)
        end)

        vim.schedule(function()
          api.nvim_buf_set_lines(tmp_buf, 0, -1, false, lines)
          on_finish({ bufnr = tmp_buf, client = ctx.client })
        end)
        return
      end

      ctx.client:request(
        'textDocument/hover',
        { textDocument = { uri = label.location.uri }, position = label.location.range.start },
        ---@param result lsp.Hover?
        function(_, result, _, _)
          if result then
            local md_lines = lsp.util.convert_input_to_markdown_lines(result.contents)
            if #md_lines > 0 then
              if #lines > 0 then
                -- blank line between label parts
                lines[#lines + 1] = ''
              end
              lines[#lines + 1] = string.format('# `%s`', label.value)
              vim.list_extend(lines, md_lines)
            end
          end
          fetch_hover(next(labels, idx))
        end,
        bufnr
      )
    end

    fetch_hover(next(labels))

    return 1
  end, {
    range = vim.range(
      vim.pos(row0, col0, { buf = bufnr }),
      vim.pos(row0, col0 + 2, { buf = bufnr })
    ),
    clients = { lsp.get_client_by_id(self.client_id) },
  }, function(ctx)
    assert(ctx.bufnr)
    if ctx.bufnr == bufnr then
      done(false)
    else
      done({ bufnr = ctx.bufnr, filetype = 'markdown' })
    end
  end)
end

--- @type Hover.Provider[]
local providers = {}

--- @param client vim.lsp.Client
local function register_lsp_provider(client)
  if
    not client:supports_method('textDocument/hover')
    or not client:supports_method('textDocument/inlayHint')
  then
    return
  end

  local lsp_provider = InlayHintProvider:new(client.id)
  lsp_providers[client.id] = {
    name = client.name,
    enabled = function(bufnr)
      return lsp_provider:enabled(bufnr)
    end,
    execute = function(params, done)
      lsp_provider:execute(params, done)
    end,
  }
  providers[#providers + 1] = lsp_providers[client.id]
end

api.nvim_create_autocmd('LspAttach', {
  callback = function(args)
    local client_id = args.data.client_id
    if not lsp_providers[client_id] then
      local client = assert(lsp.get_client_by_id(client_id))
      register_lsp_provider(client)
    end
  end,
})

-- TODO(lewis6991): reliably unregister providers when a client is destroyed.
-- Not currently possible because LspDetach is triggered before the buffer is
-- detached. Possibly need a LspExit event or similar.
-- api.nvim_create_autocmd('LspDetach', {
--   callback = function(args)
--     ...
--   end,
-- })

for _, client in pairs(lsp.get_clients()) do
  register_lsp_provider(client)
end

return {
  name = 'InlayHint',
  priority = 1000,
  providers = providers,
}
