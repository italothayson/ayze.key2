script_name("AYZE MENU")
script_author("AYZE")
script_version("1.8")

local imgui = require 'mimgui'
local ffi = require 'ffi'
local bit = require 'bit'
local hasReq, requests = pcall(require, 'requests')
local hasEffil, effil = pcall(require, 'effil')   -- requisicoes em thread separada (sem travar o jogo)
local hasVk, vkeys = pcall(require, 'vkeys')       -- so existe no PC

-- ============================================================
-- PLATAFORMA  (PC = MoonLoader | MOBILE = MonetLoader)
-- ============================================================
local MOBILE = (rawget(_G, "MONET_VERSION") ~= nil) or (rawget(_G, "MONET_DPI_SCALE") ~= nil)
if not MOBILE and jit and (jit.os == "Android" or jit.os == "Linux") then MOBILE = true end

-- Se o menu ficar grande/pequeno demais no celular, force um valor aqui (ex: 1.5). nil = automatico.
local MOBILE_SCALE = nil

-- ============================================================
-- CONFIG  (SCRIPT_VERSION tem que ser igual ao publicado no painel)
-- ============================================================
local SCRIPT_VERSION = "1.58"
local API_BASE = "https://c22ayze.discloud.dev" -- sem barra no final
local HEARTBEAT_INTERVAL = 5000   -- ms entre verificacoes
local MAX_FALHAS = 6              -- falhas seguidas de conexao ate bloquear
local HTTP_TIMEOUT = 12           -- segundos ate desistir de uma requisicao
local CFG_DIR = getWorkingDirectory() .. "/config"
pcall(function()
    if not doesDirectoryExist(CFG_DIR) then createDirectory(CFG_DIR) end
end)
local KEY_FILE = CFG_DIR .. "/ayze_key.txt"
local CFG_FILE = CFG_DIR .. "/ayze_config.txt"
local HWID_FILE = CFG_DIR .. "/ayze_hwid.txt"   -- so usado no mobile
local OPEN_COMMAND = "ayze"       -- /ayze abre/fecha o menu

-- Medidas base do layout (em "pixels de referencia", multiplicadas por S)
local W_MAIN, H_MAIN = 800, 500
local SIDE_W = 230
local CARD_X, CARD_W, CARD_GAP = 25, 507, 25
local AUTH_W, AUTH_H = 380, 330

-- Escala da interface: 1.0 no PC; no mobile e calculada pela tela (veja computeScale)
local S = 1.0

-- ============================================================
-- ESTADO
-- ============================================================
local showAuthWindow = imgui.new.bool(false)
local showMainMenu = imgui.new.bool(false)
local showUpdateWindow = imgui.new.bool(false)
local isAuthenticated = false
local selectedTab = 1
local visualSub = 0   -- aba VISUAL: 0 = botoes | 1 = ESP PLAYER | 2 = ESP VEICULO
local busy = false

local inputKey = imgui.new.char[256]("")
local statusText = ""
local isErrorStatus = true
local userName = "Usuario"
local expiresText = "..."
local sessionKey = ""
local falhas = 0

local updateInfo = { version = "", mandatory = false, busy = false, msg = "", err = false }
local dismissedVersion = ""

local TABS = { "INICIO", "VISUAL", "VEICULO", "PLAYER", "CONFIG" }

-- Protecao local de sync recebido; desligada ate o usuario ativar.
local protection = { open = false, enabled = imgui.new.bool(false), antiShake = imgui.new.bool(true), blocked = 0, shakeBlocked = 0, notices = {} }

-- AUTO DIVULGACAO (aba INICIO)
local autoDiv = {
    open = false,
    uiActive = imgui.new.bool(false),
    message = imgui.new.char[145](""),
    interval = imgui.new.int(10),
    active = false,
    elapsed = 0,
    status = "PARADO",
}


-- ============================================================
-- VEHICLE LIST (aba VEICULO) — estado
-- ============================================================
local vehlist = {
    selected = -1,
    search = imgui.new.char[64](""),
    maxDist = imgui.new.int(2000),
    hideOccupied = imgui.new.bool(false),
    open = true,        -- caixa aberta / minimizada
    filters = false,    -- filtros (busca, distancia, ocupados) abertos / minimizados
    selName = "",
    delKey = 0,          -- tecla de atalho do DELETAR VEICULO (0 = nenhuma)
    bindingDel = false,
    delEnabled = imgui.new.bool(false),   -- chavinha do DELETAR VEICULO
    delOpen = false,                      -- opcoes do card abertas / minimizadas
}

-- Estados de exemplo das funcoes (troque pelas suas)
local feat = {
    visual = { imgui.new.bool(false), imgui.new.bool(false) },
    veiculo = { imgui.new.bool(false), imgui.new.bool(false) },
    player = { imgui.new.bool(false), imgui.new.bool(false) },
}

-- Config salva (tecla do menu + cor)
-- TREMULACAO (aba PLAYER): chavinha habilita | segure o atalho para acionar
local shake = {
    heldSim = false,
    enabled = imgui.new.bool(false),
    key = 0,
    binding = false,
    open = false,
}

-- GOD MOD (aba PLAYER): chavinha liga / desliga
local god = {
    enabled = imgui.new.bool(false),   -- chavinha: habilita a funcao
    key = 0,                           -- tecla de atalho (0 = nenhuma)
    active = false,                    -- ligado/desligado pelo atalho (a chavinha NAO muda)
    binding = false,
    open = false,
    wasOn = false,
}
-- god mod efetivo: sem atalho = so a chavinha | com atalho = chavinha + atalho
local function godIsOn()
    return god.enabled[0] and (god.key == 0 or god.active)
end

local upside = {
    enabled = imgui.new.bool(false),
    key = 0,
    active = false,
    binding = false,
    open = false,
}
local function upsideIsOn()
    return upside.enabled[0] and (upside.key == 0 or upside.active)
end

local invisibility = {
    enabled = imgui.new.bool(false),
    key = 0,
    binding = false,
    open = false,
}
local function invisibilityIsOn()
    return invisibility.enabled[0]
end

local hotkey = 0x71                 -- F2 (so PC)
local bindingKey = false
local accentRGB = { 115, 64, 230 }  -- roxo padrao
local dirtyCfg = false
local lastCfgChange = 0
local saveKeyOpt = true                -- SALVAR KEY neste aparelho
local autoLoginOpt = true              -- INICIAR AUTOMATICAMENTE com a key salva

local function saveConfig()
    local f = io.open(CFG_FILE, "w")
    if not f then return end
    f:write(string.format("hotkey=%d\nr=%d\ng=%d\nb=%d\nsavekey=%d\nautologin=%d\ndelkey=%d\nshakekey=%d\ngodkey=%d\nupsidekey=%d\ninvisibilitykey=%d\n",
        hotkey, accentRGB[1], accentRGB[2], accentRGB[3], saveKeyOpt and 1 or 0, autoLoginOpt and 1 or 0, vehlist.delKey, shake.key, god.key, upside.key, invisibility.key))
    f:close()
end

local function loadConfig()
    local f = io.open(CFG_FILE, "r")
    if not f then return end
    for line in f:lines() do
        local k, v = line:match("^(%w+)=(%-?%d+)$")
        v = tonumber(v)
        if k and v then
            if k == "hotkey" then hotkey = v
            elseif k == "r" then accentRGB[1] = v
            elseif k == "g" then accentRGB[2] = v
            elseif k == "b" then accentRGB[3] = v
            elseif k == "savekey" then saveKeyOpt = (v == 1)
            elseif k == "autologin" then autoLoginOpt = (v == 1)
            elseif k == "delkey" then vehlist.delKey = v
            elseif k == "shakekey" then shake.key = v
            elseif k == "godkey" then god.key = v
            elseif k == "upsidekey" then upside.key = v
            elseif k == "invisibilitykey" then invisibility.key = v end
        end
    end
    f:close()
end
loadConfig()

local function fixOpts()
    if not saveKeyOpt then autoLoginOpt = false end
end
fixOpts()

local function keyName(id)
    if id == 0 then return "NENHUMA" end
    if hasVk then
        local ok, n = pcall(vkeys.id_to_name, id)
        if ok and n then return tostring(n):upper() end
    end
    return string.format("0x%02X", id)
end

-- ============================================================
-- HWID
--   PC:     serial do volume C: + nome do PC + CPU
--   MOBILE: ID aleatorio gerado uma vez e salvo em config/ayze_hwid.txt
-- ============================================================
if not MOBILE then
    ffi.cdef[[ int GetVolumeInformationA(const char*, char*, unsigned long, unsigned long*, unsigned long*, unsigned long*, char*, unsigned long); ]]
end

local function getHWID()
    if MOBILE then
        local f = io.open(HWID_FILE, "r")
        if f then
            local id = (f:read("*a") or ""):gsub("%s", "")
            f:close()
            if id ~= "" then return id end
        end
        math.randomseed(os.time() + math.floor(os.clock() * 100000))
        math.random(); math.random()
        local t = {}
        for i = 1, 16 do t[i] = string.format("%X", math.random(0, 15)) end
        local id = "MOB-" .. table.concat(t)
        local w = io.open(HWID_FILE, "w")
        if w then w:write(id); w:close() end
        return id
    end

    local serial = ffi.new("unsigned long[1]")
    ffi.C.GetVolumeInformationA("C:\\", nil, 0, serial, nil, nil, nil, 0)
    local pc = (os.getenv("COMPUTERNAME") or "PC"):gsub("[^%w_-]", "")
    local cpu = (os.getenv("PROCESSOR_IDENTIFIER") or "CPU"):gsub("[^%w]", ""):sub(1, 16)
    return string.format("%08X-%s-%s", tonumber(serial[0]), pc, cpu)
end
local HWID = getHWID()

-- ============================================================
-- API
-- ============================================================
local function urlenc(s)
    return (tostring(s):gsub("[^%w_%-%.]", function(c) return string.format("%%%02X", c:byte()) end))
end

-- POST assincrono (outra thread do SO); chamar so dentro de lua_thread/main
local function apiPostRaw(path, key, extra)
    local body = "key=" .. urlenc(key) .. "&hwid=" .. urlenc(HWID) .. "&version=" .. urlenc(SCRIPT_VERSION) .. (extra or "")
    local url = API_BASE .. path

    if not hasEffil then
        if not hasReq then return nil end
        return requests.post(url, {
            data = body,
            headers = { ["Content-Type"] = "application/x-www-form-urlencoded" }
        })
    end

    -- A funcao da thread e criada a partir de TEXTO (loadstring) para ficar sem upvalues.
    -- O effil nao consegue copiar closures, e a ofuscacao transforma a funcao numa closure.
    local mk = loadstring or load
    local threadFn = mk([=[
        return function(u, b)
            local rq = require 'requests'
            local ok, resp = pcall(rq.post, u, {
                data = b,
                headers = { ["Content-Type"] = "application/x-www-form-urlencoded" }
            })
            if ok and resp then return true, resp.status_code, resp.text end
            return false
        end
    ]=])()
    local runner = effil.thread(threadFn)
    local th = runner(url, body)

    local t0 = os.clock()
    while true do
        local st = th:status()
        if st == "completed" then
            local ok, code, text = th:get()
            if ok then return { status_code = code, text = text } end
            return nil
        elseif st == "failed" or st == "canceled" then
            return nil
        end
        if os.clock() - t0 > HTTP_TIMEOUT then
            pcall(function() th:cancel(0) end)
            return nil
        end
        wait(30)
    end
end

-- Tenta pela thread (effil); se ela falhar por qualquer motivo, tenta direto com requests
local function apiPost(path, key, extra)
    local ok, r = pcall(apiPostRaw, path, key, extra)
    if ok and r then return r end
    if hasReq then
        local body = "key=" .. urlenc(key) .. "&hwid=" .. urlenc(HWID) .. "&version=" .. urlenc(SCRIPT_VERSION) .. (extra or "")
        local ok2, r2 = pcall(requests.post, API_BASE .. path, {
            data = body,
            headers = { ["Content-Type"] = "application/x-www-form-urlencoded" }
        })
        if ok2 and r2 then return r2 end
    end
    return nil
end

local function validateKey(key, heartbeat)
    local ok, resp = pcall(apiPost, "/api/validate", key, heartbeat and "&hb=1" or "")
    if not ok or not resp then return { status = "ERRO" } end

    local t = resp.text or ""
    local st = t:match('"status"%s*:%s*"([%w_]+)"')

    if resp.status_code ~= 200 then
        if not st then
            if resp.status_code == 401 or resp.status_code == 403 then
                st = "CANCELADA"
            else
                return { status = "ERRO" }
            end
        end
    end
    if t == "" and not st then return { status = "ERRO" } end

    local name = t:match('"name"%s*:%s*"([^"]*)"')
        or t:match('"username"%s*:%s*"([^"]*)"')
        or t:match('"nome"%s*:%s*"([^"]*)"')
        or t:match('"user"%s*:%s*"([^"]*)"')
        or t:match('"owner"%s*:%s*"([^"]*)"')
        or t:match('"client"%s*:%s*"([^"]*)"')
        or ""

    return {
        status = st or "ERRO",
        expires = tonumber(t:match('"expires"%s*:%s*(%d+)')) or 0,
        update = t:find('"update"%s*:%s*true') ~= nil,
        mandatory = t:find('"mandatory"%s*:%s*true') ~= nil,
        version = t:match('"version"%s*:%s*"([%d%.]*)"') or "",
        name = name,
    }
end

local function downloadUpdate(key)
    local ok, resp = pcall(apiPost, "/api/update/download", key)
    if not ok or not resp or resp.status_code ~= 200 or #resp.text < 200 or not resp.text:find("SCRIPT_VERSION", 1, true) then
        return false
    end
    local f = io.open(thisScript().path, "wb")
    if not f then return false end
    f:write(resp.text); f:close()
    return true
end

-- Status que o servidor retorna quando a key esta OK (ajuste se o seu painel usar outro nome)
local OK_STATUS = { OK = true, ATIVA = true, ATIVO = true, VALIDA = true, VALID = true, SUCCESS = true }

local STATUS_MSG = {
    INVALIDA = "KEY INVALIDA OU INEXISTENTE!",
    EXPIRADA = "KEY EXPIRADA! ADQUIRA UMA NOVA.",
    CANCELADA = "KEY BANIDA / CANCELADA PELO ADMIN!",
    REVOGADA = "KEY REVOGADA PELO ADMIN!",
    REVOGADO = "KEY REVOGADA PELO ADMIN!",
    BANIDO = "DISPOSITIVO BANIDO!",
    HWID_INVALIDO = "KEY JA VINCULADA A OUTRO DISPOSITIVO!",
    ERRO = "FALHA AO CONECTAR AO SERVIDOR!",
}

-- ============================================================
-- ARQUIVO DA KEY (login automatico)
-- ============================================================
local function saveKey(k)
    local f = io.open(KEY_FILE, "w")
    if f then f:write(k); f:close() end
end
local function loadKey()
    local f = io.open(KEY_FILE, "r")
    if not f then return nil end
    local k = f:read("*a"); f:close()
    k = (k or ""):gsub("%s", "")
    return k ~= "" and k or nil
end
local function deleteKey() os.remove(KEY_FILE) end

-- ============================================================
-- ACOES
-- ============================================================
local function chat(msg, color)
    pcall(function() sampAddChatMessage("[AYZE] " .. msg, color or 0xFF4DA6FF) end)
end

local function hotkeyHint()
    if MOBILE then return "/" .. OPEN_COMMAND .. " ou o botao flutuante" end
    if hotkey ~= 0 then return "/" .. OPEN_COMMAND .. " ou " .. keyName(hotkey) end
    return "/" .. OPEN_COMMAND
end

local function setExpires(expires)
    expiresText = (expires == 0) and "Vitalicio" or os.date("%d/%m/%Y %H:%M", expires)
end

local function lockMenu(msg)
    isAuthenticated = false
    showMainMenu[0] = false
    showUpdateWindow[0] = false
    statusText = msg or "ACESSO REVOGADO PELO PAINEL!"
    isErrorStatus = true
    showAuthWindow[0] = true
    chat(statusText, 0xFFFF4444)
end

local function requestUpdate(version, mandatory)
    if not mandatory and dismissedVersion == version then return end
    updateInfo.version = version
    updateInfo.mandatory = mandatory
    if not updateInfo.busy then updateInfo.msg = ""; updateInfo.err = false end
    showUpdateWindow[0] = true
    if mandatory then
        isAuthenticated = false
        showMainMenu[0] = false
        showAuthWindow[0] = false
    end
end

local function doUpdate()
    if updateInfo.busy then return end
    updateInfo.busy = true
    updateInfo.err = false
    updateInfo.msg = "BAIXANDO ATUALIZACAO..."
    lua_thread.create(function()
        if downloadUpdate(sessionKey) then
            updateInfo.msg = "ATUALIZADO! RECARREGANDO..."
            wait(1000)
            thisScript():reload()
        else
            updateInfo.msg = "FALHA AO BAIXAR A ATUALIZACAO!"
            updateInfo.err = true
            updateInfo.busy = false
        end
    end)
end

local function activateKey(key, silent)
    if busy then return end
    key = (key or ""):gsub("%s", "")
    if key == "" then
        statusText = "DIGITE SUA KEY!"
        isErrorStatus = true
        return
    end
    busy = true
    isErrorStatus = false
    statusText = "VERIFICANDO KEY..."
    lua_thread.create(function()
        local r = validateKey(key, false)
        if OK_STATUS[r.status] then
            sessionKey = key
            isAuthenticated = true
            falhas = 0
            userName = (r.name ~= "" and r.name) or "Usuario"
            setExpires(r.expires)
            if saveKeyOpt then saveKey(key) else deleteKey() end
            statusText = ""
            showAuthWindow[0] = false
            if r.update then
                requestUpdate(r.version, r.mandatory)
            end
            -- o menu NAO abre sozinho: so com o comando, a tecla (PC) ou o botao flutuante (mobile)
            if not (r.update and r.mandatory) then
                if silent then
                    chat("Login automatico realizado! Use " .. hotkeyHint() .. " para abrir o menu.")
                else
                    chat("Key ativada! Use " .. hotkeyHint() .. " para abrir o menu.")
                end
            end
        else
            isAuthenticated = false
            isErrorStatus = true
            statusText = STATUS_MSG[r.status] or ("KEY INVALIDA (" .. tostring(r.status) .. ")")
            if r.status ~= "ERRO" then deleteKey() end
            if silent then showAuthWindow[0] = true end
        end
        busy = false
    end)
end

local function toggleMenu()
    if updateInfo.mandatory and showUpdateWindow[0] then return end
    if isAuthenticated then
        showMainMenu[0] = not showMainMenu[0]
    else
        showAuthWindow[0] = not showAuthWindow[0]
    end
end

-- ============================================================
-- ATALHOS: uma funcao so, usada pela tecla real (PC) e pelo simulador (mobile)
-- ============================================================
local function processHotkey(vk)
    -- GOD MOD: o atalho liga/desliga o god, sem mexer na chavinha
    if god.key ~= 0 and vk == god.key and god.enabled[0] and isAuthenticated
        and isSampAvailable() and not sampIsChatInputActive() and not sampIsDialogActive()
        and not imgui.GetIO().WantTextInput then
        god.active = not god.active
    end

    -- CABECA PARA BAIXO: o atalho liga/desliga o upside, sem mexer na chavinha
    if upside.key ~= 0 and vk == upside.key and upside.enabled[0] and isAuthenticated
        and isSampAvailable() and not sampIsChatInputActive() and not sampIsDialogActive()
        and not imgui.GetIO().WantTextInput then
        upside.active = not upside.active
    end

    -- INVISIBILIDADE: botao e atalho alternam o mesmo estado.
    if invisibility.key ~= 0 and vk == invisibility.key and isAuthenticated
        and isSampAvailable() and not sampIsChatInputActive() and not sampIsDialogActive()
        and not imgui.GetIO().WantTextInput then
        invisibility.enabled[0] = not invisibility.enabled[0]
    end

    if vehlist.delKey ~= 0 and vk == vehlist.delKey and vehlist.delEnabled[0] and isAuthenticated and vehlist.delete
        and isSampAvailable() and not sampIsChatInputActive() and not sampIsDialogActive()
        and not imgui.GetIO().WantTextInput then
        vehlist.delete()
    end

    if hotkey ~= 0 and vk == hotkey and isSampAvailable()
        and not sampIsChatInputActive() and not sampIsDialogActive() then
        toggleMenu()
    end
end

-- ============================================================
-- SIMULADOR DE TECLAS (mobile)
-- botoes flutuantes na tela que simulam teclas do PC
-- ============================================================
local keysim = {
    cardOpen = false,
    file = CFG_DIR .. "/ayze_keysim.txt",
    buttons = {},                        -- { id, vk, x, y (fracao da tela), size (px de referencia) }
    nextId = 1,
    visible = imgui.new.bool(true),      -- mostrar os botoes na tela
    editing = imgui.new.bool(false),     -- modo editar (mover / redimensionar)
    pickerOpen = imgui.new.bool(false),  -- janela com o teclado
    selected = 0,                        -- botao em edicao
    lastSel = 0,
    sizeBuf = imgui.new.int(64),
    dirty = false,
}

-- nomes curtos (cabem no botao)
keysim.names = {
    [0x20] = "SPC", [0x09] = "TAB", [0x0D] = "ENT", [0x2D] = "INS", [0x2E] = "DEL",
    [0x24] = "HOM", [0x23] = "END", [0x21] = "PGU", [0x22] = "PGD",
    [0x25] = "<", [0x26] = "^", [0x27] = ">", [0x28] = "v",
}
for c = 0x41, 0x5A do keysim.names[c] = string.char(c) end
for c = 0x30, 0x39 do keysim.names[c] = string.char(c) end
for i = 1, 12 do keysim.names[0x6F + i] = "F" .. i end

-- teclado virtual (linhas)
keysim.rows = {
    { 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x30 },
    { 0x51, 0x57, 0x45, 0x52, 0x54, 0x59, 0x55, 0x49, 0x4F, 0x50 },
    { 0x41, 0x53, 0x44, 0x46, 0x47, 0x48, 0x4A, 0x4B, 0x4C },
    { 0x5A, 0x58, 0x43, 0x56, 0x42, 0x4E, 0x4D },
    { 0x70, 0x71, 0x72, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79 },
    { 0x7A, 0x7B, 0x20, 0x09, 0x0D, 0x2D, 0x2E, 0x24 },
    { 0x23, 0x21, 0x22, 0x25, 0x26, 0x27, 0x28 },
}

-- ------------------------------------------------------------
-- FUNCOES DO MENU que um botao simulado pode acionar (lista extensivel).
-- Para adicionar uma funcao nova, inclua uma entrada aqui:
--   { name = "NOME",
--     get   = function(vk) return <esta tecla ja esta ligada a funcao?> end,
--     set   = function(vk) <liga a funcao a esta tecla> end,
--     clear = function(vk) <desliga a funcao desta tecla> end }
-- (a funcao so dispara pela tecla/atalho que ela ja usa no PC)
-- ------------------------------------------------------------
keysim.functions = {
    { name = "SO A TECLA" },
    { name = "DELETAR VEICULO",
      get   = function(vk) return vehlist.delKey == vk end,
      set   = function(vk) vehlist.delKey = vk end,
      clear = function(vk) if vehlist.delKey == vk then vehlist.delKey = 0 end end },
    { name = "TREMULACAO",
      get   = function(vk) return shake.key == vk end,
      set   = function(vk) shake.key = vk end,
      clear = function(vk) if shake.key == vk then shake.key = 0 end end },
    { name = "GOD MOD",
      get   = function(vk) return god.key == vk end,
      set   = function(vk) god.key = vk end,
      clear = function(vk) if god.key == vk then god.key = 0 end end },
    { name = "CABECA PARA BAIXO",
      get   = function(vk) return upside.key == vk end,
      set   = function(vk) upside.key = vk end,
      clear = function(vk) if upside.key == vk then upside.key = 0 end end },
    { name = "INVISIBILIDADE",
      get   = function(vk) return invisibility.key == vk end,
      set   = function(vk) invisibility.key = vk end,
      clear = function(vk) if invisibility.key == vk then invisibility.key = 0 end end },
    { name = "ABRIR / FECHAR MENU",
      get   = function(vk) return hotkey == vk end,
      set   = function(vk) hotkey = vk end,
      clear = function(vk) if hotkey == vk then hotkey = 0 end end },
}

-- indice (1..n) da funcao atual da tecla
keysim.fnIndex = function(vk)
    for i = 2, #keysim.functions do
        if keysim.functions[i].get(vk) then return i end
    end
    return 1
end

-- passa para a proxima funcao da lista e salva
keysim.cycleFn = function(vk)
    local cur = keysim.fnIndex(vk)
    for i = 2, #keysim.functions do keysim.functions[i].clear(vk) end
    local nxt = cur % #keysim.functions + 1
    if keysim.functions[nxt].set then keysim.functions[nxt].set(vk) end
    saveConfig()
end

keysim.label = function(vk)
    if vk == 0 then return "NENHUMA" end
    return keysim.names[vk] or keyName(vk)
end

keysim.find = function(vk)
    for i, b in ipairs(keysim.buttons) do
        if b.vk == vk then return i end
    end
    return 0
end

keysim.save = function()
    local f = io.open(keysim.file, "w")
    if not f then return end
    f:write("visible=" .. (keysim.visible[0] and 1 or 0) .. "\n")
    for _, b in ipairs(keysim.buttons) do
        f:write(string.format("btn=%d,%.5f,%.5f,%d\n", b.vk, b.x, b.y, b.size))
    end
    f:close()
    keysim.dirty = false
end

keysim.load = function()
    local f = io.open(keysim.file, "r")
    if not f then return end
    for line in f:lines() do
        local vk, x, y, sz = line:match("^btn=(%d+),([%d%.%-]+),([%d%.%-]+),(%d+)")
        if vk then
            keysim.buttons[#keysim.buttons + 1] = {
                id = keysim.nextId, vk = tonumber(vk), x = tonumber(x), y = tonumber(y), size = tonumber(sz),
            }
            keysim.nextId = keysim.nextId + 1
        elseif line:match("^visible=0") then
            keysim.visible[0] = false
        end
    end
    f:close()
end
pcall(keysim.load)

-- cria um botao novo (ou seleciona o que ja existe) e entra no modo editar
keysim.add = function(vk)
    local i = keysim.find(vk)
    if i == 0 then
        local n = #keysim.buttons
        keysim.buttons[n + 1] = {
            id = keysim.nextId, vk = vk, size = 64,
            x = 0.42 + 0.04 * (n % 6), y = 0.38 + 0.06 * (n % 6),
        }
        keysim.nextId = keysim.nextId + 1
        i = n + 1
    end
    keysim.selected = i
    keysim.editing[0] = true
    keysim.visible[0] = true
    keysim.pickerOpen[0] = false
    keysim.save()
end

-- aperta a tecla simulada
keysim.press = function(vk)
    -- se o menu esta esperando uma tecla (TECLA DE ATALHO), o botao toca como se fosse a tecla
    if bindingKey then
        bindingKey = false
        hotkey = vk
        saveConfig()
        return
    end
    if vehlist.bindingDel then
        vehlist.bindingDel = false
        vehlist.delKey = vk
        saveConfig()
        return
    end
    if shake.binding then
        shake.binding = false
        shake.key = vk
        saveConfig()
        return
    end
    if god.binding then
        god.binding = false
        god.key = vk
        saveConfig()
        return
    end
    if upside.binding then
        upside.binding = false
        upside.key = vk
        saveConfig()
        return
    end
    if invisibility.binding then
        invisibility.binding = false
        invisibility.key = vk
        saveConfig()
        return
    end
    -- O atalho da tremulacao e lido pelo estado pressionado do simulador.
    if shake.key ~= 0 and vk == shake.key then return end
    processHotkey(vk)
    -- tambem injeta no jogo (outros scripts que leem teclado), se o loader suportar
    local fn = rawget(_G, "setVirtualKeyDown")
    if fn then
        lua_thread.create(function()
            pcall(fn, vk, true)
            wait(60)
            pcall(fn, vk, false)
        end)
    end
end

-- Tecla de atalho (so PC): captura a tecla pra trocar e abre/fecha o menu
if not MOBILE then
    addEventHandler("onWindowMessage", function(msg, wparam, lparam)
        if msg ~= 0x100 and msg ~= 0x104 then return end
        if bit.band(lparam, 0x40000000) ~= 0 then return end -- ignora tecla repetida

        if bindingKey then
            consumeWindowMessage(true, true)
            bindingKey = false
            if wparam ~= 0x1B then -- ESC cancela
                hotkey = wparam
                saveConfig()
            end
            return
        end

        -- captura da tecla do DELETAR VEICULO
        if vehlist.bindingDel then
            consumeWindowMessage(true, true)
            vehlist.bindingDel = false
            if wparam == 0x08 then          -- BACKSPACE remove a tecla
                vehlist.delKey = 0
                saveConfig()
            elseif wparam ~= 0x1B then      -- ESC cancela
                vehlist.delKey = wparam
                saveConfig()
            end
            return
        end

        -- captura da tecla do GOD MOD
        if god.binding then
            consumeWindowMessage(true, true)
            god.binding = false
            if wparam == 0x08 then
                god.key = 0
                saveConfig()
            elseif wparam ~= 0x1B then
                god.key = wparam
                saveConfig()
            end
            return
        end

        -- captura da tecla do CABECA PARA BAIXO
        if upside.binding then
            consumeWindowMessage(true, true)
            upside.binding = false
            if wparam == 0x08 then
                upside.key = 0
                saveConfig()
            elseif wparam ~= 0x1B then
                upside.key = wparam
                saveConfig()
            end
            return
        end

        -- captura da tecla do INVISIBILIDADE
        if invisibility.binding then
            consumeWindowMessage(true, true)
            invisibility.binding = false
            if wparam == 0x08 then
                invisibility.key = 0
                saveConfig()
            elseif wparam ~= 0x1B then
                invisibility.key = wparam
                saveConfig()
            end
            return
        end

        -- captura da tecla da TREMULACAO
        if shake.binding then
            consumeWindowMessage(true, true)
            shake.binding = false
            if wparam == 0x08 then
                shake.key = 0
                saveConfig()
            elseif wparam ~= 0x1B then
                shake.key = wparam
                saveConfig()
            end
            return
        end

        processHotkey(wparam)
    end)
end

-- ============================================================
-- UI / TEMA  (todas as cores SOLIDAS, alpha = 1)
-- ============================================================
local function rgb(r, g, b) return imgui.ImVec4(r / 255, g / 255, b / 255, 1.0) end
local function clamp(x) return math.max(0, math.min(255, math.floor(x + 0.5))) end
local function shade(c, t) -- t > 0 clareia, t < 0 escurece
    local r, g, b = c[1], c[2], c[3]
    if t >= 0 then
        r, g, b = r + (255 - r) * t, g + (255 - g) * t, b + (255 - b) * t
    else
        r, g, b = r * (1 + t), g * (1 + t), b * (1 + t)
    end
    return rgb(clamp(r), clamp(g), clamp(b))
end

-- helpers de escala: V = tamanho/posicao escalado | P = ponto escalado relativo a uma origem
local function V(x, y) return imgui.ImVec2(x * S, y * S) end
local function P(o, x, y) return imgui.ImVec2(o.x + x * S, o.y + y * S) end

local C = {
    bg      = rgb(14, 12, 24),     -- fundo da janela
    side    = rgb(11, 10, 20),     -- barra lateral
    card    = rgb(21, 19, 36),     -- cards
    panel2  = rgb(31, 28, 52),     -- itens / inputs
    panel3  = rgb(44, 40, 72),     -- hover
    border  = rgb(40, 36, 66),
    text    = rgb(236, 238, 250),
    dim     = rgb(134, 138, 168),
    red     = rgb(255, 99, 105),
    redBg   = rgb(58, 20, 26),
    redBd   = rgb(140, 40, 50),
    green   = rgb(74, 222, 128),
    greenBg = rgb(16, 52, 34),
    greenBd = rgb(34, 120, 72),
}

-- cores que dependem da cor do menu
local function setAccent(r, g, b)
    accentRGB = { r, g, b }
    C.blue = rgb(r, g, b)
    C.blueH = shade(accentRGB, 0.18)
    C.blueA = shade(accentRGB, -0.25)
    C.accent = shade(accentRGB, 0.30)
    C.infoBg = rgb(clamp(14 + r * 0.14), clamp(12 + g * 0.14), clamp(24 + b * 0.14))
    C.infoBd = C.blue
end
setAccent(accentRGB[1], accentRGB[2], accentRGB[3])

local function u32(c) return imgui.GetColorU32Vec4(c) end

local function applyTheme()
    local s = imgui.GetStyle()
    s.WindowRounding = 12 * S
    s.ChildRounding = 8 * S
    s.FrameRounding = 8 * S
    s.GrabRounding = 6 * S
    s.PopupRounding = 8 * S
    s.ScrollbarRounding = 8 * S
    s.ScrollbarSize = (MOBILE and 8 or 6) * S
    s.WindowBorderSize = 1
    s.ChildBorderSize = 1
    s.FrameBorderSize = 0
    s.WindowPadding = V(18, 16)
    s.FramePadding = V(12, 10)
    s.ItemSpacing = V(10, 10)
    local c = s.Colors
    c[imgui.Col.WindowBg] = C.bg
    c[imgui.Col.ChildBg] = C.card
    c[imgui.Col.PopupBg] = C.card
    c[imgui.Col.Border] = C.border
    c[imgui.Col.Text] = C.text
    c[imgui.Col.TextDisabled] = C.dim
    c[imgui.Col.FrameBg] = C.panel2
    c[imgui.Col.FrameBgHovered] = C.panel3
    c[imgui.Col.FrameBgActive] = C.panel3
    c[imgui.Col.Button] = C.blue
    c[imgui.Col.ButtonHovered] = C.blueH
    c[imgui.Col.ButtonActive] = C.blueA
    c[imgui.Col.CheckMark] = C.accent
    c[imgui.Col.SliderGrab] = C.accent
    c[imgui.Col.SliderGrabActive] = C.blueH
    c[imgui.Col.Separator] = C.border
    c[imgui.Col.ScrollbarBg] = C.bg
    c[imgui.Col.ScrollbarGrab] = C.blue
    c[imgui.Col.ScrollbarGrabHovered] = C.blueH
    c[imgui.Col.ScrollbarGrabActive] = C.blueA
    c[imgui.Col.TextSelectedBg] = C.blueA
end

-- Escala: PC = 1.0. Mobile = menor entre o DPI do aparelho e o que cabe na tela.
local function computeScale()
    if not MOBILE then return 1.0 end
    if MOBILE_SCALE then return MOBILE_SCALE end
    local ds = imgui.GetIO().DisplaySize
    if ds.x < 100 or ds.y < 100 then return S end
    local dpi = tonumber(rawget(_G, "MONET_DPI_SCALE")) or 2.0
    local fit = math.min(ds.x * 0.94 / W_MAIN, ds.y * 0.92 / H_MAIN)
    return math.max(0.8, math.min(dpi, fit))
end

local function updateScale()
    local ns = computeScale()
    if math.abs(ns - S) > 0.01 then
        S = ns
        imgui.GetIO().FontGlobalScale = S
        applyTheme()
    end
end

imgui.OnInitialize(function()
    imgui.GetIO().IniFilename = nil
    applyTheme()
    updateScale()
end)

local function centerText(text, color, scale)
    imgui.SetWindowFontScale(scale or 1.0)
    local w = imgui.CalcTextSize(text).x
    imgui.SetCursorPosX((imgui.GetWindowWidth() - w) / 2)
    imgui.TextColored(color, text)
    imgui.SetWindowFontScale(1.0)
end

-- Janela livre: aparece no centro na 1a vez e depois voce arrasta pra onde quiser
local function placeWindow(w, h)
    local io = imgui.GetIO()
    imgui.SetNextWindowPos(imgui.ImVec2(io.DisplaySize.x / 2, io.DisplaySize.y / 2), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5))
    imgui.SetNextWindowSize(V(w, h), imgui.Cond.Always)
end

local WIN_FLAGS = imgui.WindowFlags.NoResize + imgui.WindowFlags.NoCollapse
    + imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoScrollbar
    + imgui.WindowFlags.NoScrollWithMouse

local function accentBar()
    local dl = imgui.GetWindowDrawList()
    local p = imgui.GetWindowPos()
    local sz = imgui.GetWindowSize()
    dl:AddRectFilled(P(p, 22, 10), imgui.ImVec2(p.x + sz.x - 22 * S, p.y + 13 * S), u32(C.blue), 3 * S)
end

local function closeButton(id)
    local sz = imgui.GetWindowSize()
    imgui.SetCursorPos(imgui.ImVec2(sz.x - 38 * S, 20 * S))
    imgui.PushStyleColor(imgui.Col.Button, C.panel2)
    imgui.PushStyleColor(imgui.Col.ButtonHovered, C.red)
    imgui.PushStyleColor(imgui.Col.ButtonActive, C.redBd)
    imgui.PushStyleVarVec2(imgui.StyleVar.FramePadding, imgui.ImVec2(0, 0))
    local clicked = imgui.Button("X##" .. id, V(22, 22))
    imgui.PopStyleVar()
    imgui.PopStyleColor(3)
    return clicked
end

-- ------------------------------------------------------------
-- JANELA DE ATIVACAO DE KEY
-- ------------------------------------------------------------

-- mini chave liga/desliga com texto ao lado (retorna true quando clicada, e a largura usada)
local function miniToggle(id, label, tip, on)
    local I = imgui.ImVec2
    local p = imgui.GetCursorScreenPos()
    local tw = imgui.CalcTextSize(label).x
    local pw, ph, gap = 28 * S, 15 * S, 8 * S
    local clicked = imgui.InvisibleButton("##mt" .. id, I(pw + gap + tw, ph + 2 * S))
    local hovered = imgui.IsItemHovered()
    local dl = imgui.GetWindowDrawList()
    local lh = imgui.GetTextLineHeight()

    local py = p.y + 1 * S
    dl:AddRectFilled(p, I(p.x + pw, py + ph), u32(on and C.blue or C.panel3), ph / 2)
    dl:AddCircleFilled(I(on and (p.x + pw - ph / 2) or (p.x + ph / 2), py + ph / 2), ph / 2 - 3 * S, u32(on and C.text or C.dim), 14)
    local col = (on or hovered) and C.text or C.dim
    dl:AddText(I(p.x + pw + gap, p.y + (ph + 2 * S - lh) / 2), u32(col), label)

    if hovered and tip and not MOBILE then imgui.SetTooltip(tip) end
    return clicked, pw + gap + tw
end

imgui.OnFrame(function() return showAuthWindow[0] end, function(self)
    self.HideCursor = false
    updateScale()
    placeWindow(AUTH_W, AUTH_H)
    imgui.PushStyleColor(imgui.Col.Border, C.blue)
    imgui.Begin("##ayze_auth", nil, WIN_FLAGS)
    imgui.PopStyleColor()

    local I = imgui.ImVec2
    local PX = 24 * S                   -- margem lateral
    local w = (AUTH_W - 48) * S         -- largura util
    local lh = imgui.GetTextLineHeight()
    local dl = imgui.GetWindowDrawList()
    local wp = imgui.GetWindowPos()

    accentBar()
    if closeButton("auth") then showAuthWindow[0] = false end

    -- cabecalho
    imgui.SetCursorPosY(28 * S)
    centerText("AYZE", C.text, 2.0)
    imgui.SetCursorPosY(64 * S)
    centerText("MENU PREMIUM  |  ATIVACAO DE LICENCA", C.accent, 0.78)

    -- divisor com degrade
    dl:AddRectFilledMultiColor(I(wp.x + PX, wp.y + 88 * S), I(wp.x + PX + w, wp.y + 90 * S),
        u32(C.bg), u32(C.blue), u32(C.blue), u32(C.bg))

    -- status (faixa fina)
    local bg, bd, fg = C.card, C.border, C.dim
    local msg = "Digite sua key para ativar"
    if statusText ~= "" then
        msg = statusText
        if busy then bg, bd, fg = C.infoBg, C.infoBd, C.accent
        elseif isErrorStatus then bg, bd, fg = C.redBg, C.redBd, C.red
        else bg, bd, fg = C.greenBg, C.greenBd, C.green end
    end
    imgui.SetCursorPos(I(PX, 104 * S))
    imgui.PushStyleColor(imgui.Col.ChildBg, bg)
    imgui.PushStyleColor(imgui.Col.Border, bd)
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, I(8 * S, (30 * S - lh) / 2))
    imgui.BeginChild("##status", I(w, 30 * S), true, imgui.WindowFlags.NoScrollbar)
    centerText(msg, fg, 0.9)
    imgui.EndChild()
    imgui.PopStyleVar()
    imgui.PopStyleColor(2)

    -- campo da key
    imgui.SetCursorPos(I(PX, 148 * S))
    imgui.TextColored(C.dim, "SUA KEY")
    local yIn = 148 * S + lh + 5 * S
    imgui.SetCursorPos(I(PX, yIn))
    imgui.PushItemWidth(w)
    imgui.PushStyleVarVec2(imgui.StyleVar.FramePadding, I(12 * S, (38 * S - lh) / 2))
    local enter = imgui.InputText("##key", inputKey, ffi.sizeof(inputKey), imgui.InputTextFlags.EnterReturnsTrue)
    imgui.PopStyleVar()
    imgui.PopItemWidth()

    -- mini botoes logo abaixo do campo
    local yTg = yIn + 38 * S + 10 * S
    imgui.SetCursorPos(I(PX + 2 * S, yTg))
    local c1 = miniToggle("save", "Salvar key", "Guarda a key neste aparelho para nao precisar digitar de novo", saveKeyOpt)
    if c1 then
        saveKeyOpt = not saveKeyOpt
        if saveKeyOpt then
            if sessionKey ~= "" then saveKey(sessionKey) end
        else
            autoLoginOpt = false
            deleteKey()
        end
        saveConfig()
    end

    local autoW = 28 * S + 8 * S + imgui.CalcTextSize("Entrar automatico").x
    imgui.SetCursorPos(I(PX + w - autoW - 2 * S, yTg))
    local c2 = miniToggle("auto", "Entrar automatico", "Ativa a key sozinho ao abrir o jogo", autoLoginOpt)
    if c2 then
        autoLoginOpt = not autoLoginOpt
        if autoLoginOpt then
            saveKeyOpt = true
            if sessionKey ~= "" then saveKey(sessionKey) end
        end
        saveConfig()
    end

    -- ativar
    local yAct = yTg + 17 * S + 16 * S
    imgui.SetCursorPos(I(PX, yAct))
    local label = busy and "VERIFICANDO..." or "ATIVAR KEY"
    if (imgui.Button(label, I(w, 40 * S)) or enter) and not busy then
        activateKey(ffi.string(inputKey))
    end

    -- rodape
    imgui.SetCursorPosY(yAct + 40 * S + 14 * S)
    centerText("Versao do menu " .. SCRIPT_VERSION .. (MOBILE and "  |  MOBILE" or ""), C.dim, 0.8)
    imgui.End()
end)

-- ------------------------------------------------------------
-- JANELA DE ATUALIZACAO
-- ------------------------------------------------------------
imgui.OnFrame(function() return showUpdateWindow[0] end, function(self)
    self.HideCursor = false
    updateScale()
    placeWindow(420, 280)
    imgui.PushStyleColor(imgui.Col.Border, C.blue)
    imgui.Begin("##ayze_update", nil, WIN_FLAGS)
    imgui.PopStyleColor()

    accentBar()
    imgui.SetCursorPosY(34 * S)
    centerText("ATUALIZACAO DISPONIVEL", C.accent, 1.2)
    imgui.Dummy(V(0, 6))
    centerText("Nova versao: " .. (updateInfo.version ~= "" and updateInfo.version or "?"), C.text, 1.0)
    centerText(updateInfo.mandatory and "ATUALIZACAO OBRIGATORIA" or "Recomendamos atualizar agora",
        updateInfo.mandatory and C.red or C.dim, 0.9)
    imgui.Dummy(V(0, 4))
    if updateInfo.msg ~= "" then
        centerText(updateInfo.msg, updateInfo.err and C.red or C.green, 0.9)
    else
        imgui.Dummy(V(0, 14))
    end
    imgui.Dummy(V(0, 4))
    local w = imgui.GetWindowWidth() - 36 * S
    if imgui.Button(updateInfo.busy and "AGUARDE..." or "ATUALIZAR AGORA", imgui.ImVec2(w, 42 * S)) then
        doUpdate()
    end
    if not updateInfo.mandatory and not updateInfo.busy then
        imgui.PushStyleColor(imgui.Col.Button, C.panel2)
        imgui.PushStyleColor(imgui.Col.ButtonHovered, C.panel3)
        if imgui.Button("DEPOIS", imgui.ImVec2(w, 36 * S)) then
            dismissedVersion = updateInfo.version
            showUpdateWindow[0] = false
        end
        imgui.PopStyleColor(2)
    end
    imgui.End()
end)

-- ------------------------------------------------------------
-- MENU PRINCIPAL (so renderiza se autenticado)
-- ------------------------------------------------------------
local PRESETS = {
    { "PADRAO",   115, 64, 230 }, { "AZUL",    41, 98, 255 },
    { "CIANO",    20, 170, 190 }, { "VERDE",   34, 160, 95 },
    { "DOURADO",  200, 160, 30 }, { "LARANJA", 225, 120, 35 },
    { "VERMELHO", 200, 45, 60 },  { "ROSA",    205, 75, 150 },
}
local cr, cg, cb = imgui.new.int(accentRGB[1]), imgui.new.int(accentRGB[2]), imgui.new.int(accentRGB[3])
local pickCol = imgui.new.float[3](accentRGB[1] / 255, accentRGB[2] / 255, accentRGB[3] / 255) -- seletor de cor

local function applyColor(r, g, b)
    cr[0], cg[0], cb[0] = r, g, b
    setAccent(r, g, b)
    applyTheme()
    dirtyCfg = true
    lastCfgChange = os.clock()
end


-- ============================================================
-- ESP (portado do ESP_Menu para mimgui)
-- ============================================================
local okEv, sampev = pcall(require, 'samp.events')

-- CABECA PARA BAIXO: altera somente a rotacao do sync a pe.
if okEv and type(sampev) == "table" then
    function sampev.onSendPlayerSync(data)
        -- INVISIBILIDADE: mesma logica do ShadowBlade do RMD.
        if invisibilityIsOn() and isAuthenticated then
            data.surfingVehicleId = 2001
        end
        if upsideIsOn() and isAuthenticated and sampIsLocalPlayerSpawned()
            and doesCharExist(PLAYER_PED) and not isCharDead(PLAYER_PED)
            and not isCharInAnyCar(PLAYER_PED) then
            -- PlayerSyncData usa array FFI 0..3, na ordem W, X, Y, Z.
            data.quaternion[0] = 0.0
            data.quaternion[1] = 0.0
            data.quaternion[2] = 1.0
            data.quaternion[3] = 0.0
        end
    end
end

-- GOD MOD: usa o estado do botao/atalho existente.
function god.isEffective()
    return godIsOn() and isAuthenticated and sampIsLocalPlayerSpawned()
        and doesCharExist(PLAYER_PED) and not isCharDead(PLAYER_PED)
end

function god.restore()
    if god.ped and doesCharExist(god.ped) then
        setCharProofs(god.ped, false, false, false, false, false)
        setCharDrownsInWater(god.ped, true)
        if god.healthBefore and getCharHealth(god.ped) > god.healthBefore then
            setCharHealth(god.ped, god.healthBefore)
        end
    end
    if god.wasOn then setPlayerNeverGetsTired(PLAYER_HANDLE, false) end
    god.wasOn, god.ped, god.healthBefore = false, nil, nil
end

function god.tick()
    if not god.isEffective() then
        if god.wasOn then god.restore() end
        return
    end
    if god.wasOn and god.ped ~= PLAYER_PED then god.restore() end
    if not god.wasOn then
        god.ped = PLAYER_PED
        god.healthBefore = getCharHealth(PLAYER_PED)
        god.wasOn = true
        if not okEv then
            chat("GOD MOD: samp.events indisponivel; bloqueio dos avisos de dano nao carregado.", 0xFFFFAA00)
        end
    end
    setCharProofs(PLAYER_PED, true, true, true, true, true)
    setCharHealth(PLAYER_PED, 1000)
    local armour = getCharArmour(PLAYER_PED)
    if armour < 100 then addArmourToChar(PLAYER_PED, 100 - armour) end
    -- Opcode nativo: evita o endereco fixo de memoria do GTA para PC.
    setCharDrownsInWater(PLAYER_PED, false)
    setPlayerNeverGetsTired(PLAYER_HANDLE, true)
    printStringNow("GOD MOD ATIVO", 100)
end

if okEv and type(sampev) == "table" then
    -- Ambos sao avisos ENVIADOS ao servidor, conforme a logica fornecida.
    function sampev.onSendGiveDamage(playerId, damage, weapon, bodypart)
        if god.isEffective() then return false end
    end
    function sampev.onSendTakeDamage(issuerId, damage, weapon, bodypart)
        if god.isEffective() then return false end
    end
end

addEventHandler("onScriptTerminate", function(script)
    if script == thisScript() and god.wasOn then pcall(god.restore) end
end)

local esp = {
    playerEnabled = imgui.new.bool(false),
    playerName = imgui.new.bool(false),
    playerId = imgui.new.bool(false),
    playerDistance = imgui.new.bool(false),
    playerHealth = imgui.new.bool(false),
    playerArmor = imgui.new.bool(false),
    playerSkeleton = imgui.new.bool(false),
    playerPlatform = imgui.new.bool(false),
    playerAfk = imgui.new.bool(false),
    playerLine = imgui.new.bool(false),
    playerMaxDistance = imgui.new.int(300),

    vehicleEnabled = imgui.new.bool(false),
    vehicleName = imgui.new.bool(false),
    vehicleDistance = imgui.new.bool(false),
    vehicleLine = imgui.new.bool(false),
    vehicleMaxDistance = imgui.new.int(300),
}

-- origem da linha: 0 = Baixo, 1 = Meio, 2 = Cima
local lineOriginNames = { "BAIXO", "MEIO", "CIMA" }
local lineOrigin = 0

-- Snapshot explicito das funcoes; nao usa loadstring nem executa o arquivo salvo.
local functionStore = {
    file = CFG_DIR .. "/ayze_functions.txt",
    status = "Clique SALVAR para guardar a configuracao atual.",
    loaded = false,
    pointers = {
        protection = protection.enabled, antiShake = protection.antiShake,
        shake = shake.enabled, god = god.enabled, upside = upside.enabled,
        invisibility = invisibility.enabled, deleteVehicle = vehlist.delEnabled,
        hideOccupied = vehlist.hideOccupied, vehicleDistance = vehlist.maxDist,
        keysVisible = keysim.visible, autoInterval = autoDiv.interval,
    },
}
for name, pointer in pairs(esp) do functionStore.pointers["esp_" .. name] = pointer end
for category, entries in pairs(feat) do
    for i, pointer in ipairs(entries) do
        functionStore.pointers["feat_" .. category .. i] = pointer
    end
end

function functionStore.write(restore)
    local lines = {"restore=" .. (restore and "1" or "0")}
    if restore then
        for name, pointer in pairs(functionStore.pointers) do
            local value = pointer[0]
            if type(value) == "boolean" then value = value and 1 or 0 end
            lines[#lines + 1] = name .. "=" .. tostring(value)
        end
        local extra = {
            godActive = god.active and 1 or 0, upsideActive = upside.active and 1 or 0,
            lineOrigin = lineOrigin, autoActive = autoDiv.active and 1 or 0,
            shakeKey = shake.key, godKey = god.key, upsideKey = upside.key,
            invisibilityKey = invisibility.key, deleteKey = vehlist.delKey,
        }
        for name, value in pairs(extra) do lines[#lines + 1] = name .. "=" .. value end
        local message = ffi.string(autoDiv.message)
        lines[#lines + 1] = "message=" .. message:gsub(".", function(c)
            return string.format("%02X", c:byte())
        end)
    end
    local f = io.open(functionStore.file, "w")
    if not f then functionStore.status = "ERRO: nao foi possivel abrir a configuracao."; return false end
    local ok = f:write(table.concat(lines, "\n") .. "\n")
    local closed = f:close()
    if not ok or not closed then
        functionStore.status = "ERRO ao gravar. Tente novamente."
        return false
    end
    functionStore.status = restore and "Funcoes salvas. Serao restauradas apos o login."
        or "Nao salvar: restauracao desativada. Sessao mantida."
    return true
end

function functionStore.load()
    if functionStore.loaded then return end
    functionStore.loaded = true
    local f = io.open(functionStore.file, "r")
    if not f then return end
    local values = {}
    for line in f:lines() do
        local name, value = line:match("^([%w_]+)=(.*)$")
        if name then values[name] = value end
    end
    f:close()
    if values.restore ~= "1" then
        functionStore.status = "Restauracao de funcoes desativada."
        return
    end
    for name, pointer in pairs(functionStore.pointers) do
        local value = tonumber(values[name])
        if value and value == value and math.abs(value) < 1000000 then
            if type(pointer[0]) == "boolean" then
                if value == 0 or value == 1 then pointer[0] = value == 1 end
            else
                local low, high = 1, 3000
                if name == "autoInterval" then high = 300 end
                pointer[0] = math.max(low, math.min(high, math.floor(value)))
            end
        end
    end
    local function restoreKey(name, object, field)
        local value = tonumber(values[name])
        if value and value >= 0 and value <= 255 and value == math.floor(value) then
            object[field] = value
        end
    end
    restoreKey("shakeKey", shake, "key")
    restoreKey("godKey", god, "key")
    restoreKey("upsideKey", upside, "key")
    restoreKey("invisibilityKey", invisibility, "key")
    restoreKey("deleteKey", vehlist, "delKey")
    god.active = values.godActive == "1"
    upside.active = values.upsideActive == "1"
    local origin = tonumber(values.lineOrigin)
    if origin == 0 or origin == 1 or origin == 2 then lineOrigin = origin end
    local hex = values.message
    if hex and #hex <= 288 and #hex % 2 == 0 and not hex:find("[^%x]") then
        local message = hex:gsub("%x%x", function(pair) return string.char(tonumber(pair, 16)) end)
        ffi.fill(autoDiv.message, ffi.sizeof(autoDiv.message), 0)
        ffi.copy(autoDiv.message, message, #message)
    end
    autoDiv.active = values.autoActive == "1" and ffi.string(autoDiv.message):match("%S") ~= nil
    autoDiv.elapsed = 0
    autoDiv.status = autoDiv.active and "ATIVO" or "PARADO"
    functionStore.status = "Funcoes restauradas da ultima configuracao salva."
end

local function getLineOriginY(h)
    if lineOrigin == 1 then return h / 2 elseif lineOrigin == 2 then return 0 end
    return h
end

local vehicleNames = {
    [400] = "Landstalker", [401] = "Bravura", [402] = "Buffalo", [403] = "Linerunner", [404] = "Perenniel",
    [405] = "Sentinel", [406] = "Dumper", [407] = "Firetruck", [408] = "Trashmaster", [409] = "Stretch",
    [410] = "Manana", [411] = "Infernus", [412] = "Voodoo", [413] = "Pony", [414] = "Mule",
    [415] = "Cheetah", [416] = "Ambulance", [417] = "Leviathan", [418] = "Moonbeam", [419] = "Esperanto",
    [420] = "Taxi", [421] = "Washington", [422] = "Bobcat", [423] = "Mr Whoopee", [424] = "BF Injection",
    [425] = "Hunter", [426] = "Premier", [427] = "Enforcer", [428] = "Securicar", [429] = "Banshee",
    [430] = "Predator", [431] = "Bus", [432] = "Rhino", [433] = "Barracks", [434] = "Hotknife",
    [435] = "Article Trailer", [436] = "Previon", [437] = "Coach", [438] = "Cabbie", [439] = "Stallion",
    [440] = "Rumpo", [441] = "RC Bandit", [442] = "Romero", [443] = "Packer", [444] = "Monster",
    [445] = "Admiral", [446] = "Squalo", [447] = "Seasparrow", [448] = "Pizza", [449] = "Tram",
    [450] = "Article Trailer 2", [451] = "Turismo", [452] = "Speeder", [453] = "Reefer", [454] = "Tropic",
    [455] = "Flatbed", [456] = "Yankee", [457] = "Caddy", [458] = "Solair", [459] = "Berkley's RC Van",
    [460] = "Skimmer", [461] = "PCJ-600", [462] = "Faggio", [463] = "Freeway", [464] = "RC Baron",
    [465] = "RC Raider", [466] = "Glendale", [467] = "Oceanic", [468] = "Sanchez", [469] = "Sparrow",
    [470] = "Patriot", [471] = "Quad", [472] = "Coastguard", [473] = "Dinghy", [474] = "Hermes",
    [475] = "Sabre", [476] = "Rustler", [477] = "ZR-350", [478] = "Walton", [479] = "Regina",
    [480] = "Comet", [481] = "BMX", [482] = "Burrito", [483] = "Camper", [484] = "Marquis",
    [485] = "Baggage", [486] = "Dozer", [487] = "Maverick", [488] = "News Chopper", [489] = "Rancher",
    [490] = "FBI Rancher", [491] = "Virgo", [492] = "Greenwood", [493] = "Jetmax", [494] = "Hotring",
    [495] = "Sandking", [496] = "Blista Compact", [497] = "Police Maverick", [498] = "Boxville",
    [499] = "Benson", [500] = "Mesa", [501] = "RC Goblin", [502] = "Hotring A", [503] = "Hotring B",
    [504] = "Bloodring Banger", [505] = "Rancher", [506] = "Super GT", [507] = "Elegant", [508] = "Journey",
    [509] = "Bike", [510] = "Mountain Bike", [511] = "Beagle", [512] = "Cropduster", [513] = "Stunt",
    [514] = "Tanker", [515] = "Roadtrain", [516] = "Nebula", [517] = "Majestic", [518] = "Buccaneer",
    [519] = "Shamal", [520] = "Hydra", [521] = "FCR-900", [522] = "NRG-500", [523] = "HPV1000",
    [524] = "Cement Truck", [525] = "Towtruck", [526] = "Fortune", [527] = "Cadrona", [528] = "FBI Truck",
    [529] = "Willard", [530] = "Forklift", [531] = "Tractor", [532] = "Combine", [533] = "Feltzer",
    [534] = "Remington", [535] = "Savanna", [536] = "Blade", [537] = "Freight", [538] = "Streak",
    [539] = "Vortex", [540] = "Vincent", [541] = "Bullet", [542] = "Clover", [543] = "Sadler",
    [544] = "Firetruck LA", [545] = "Hustler", [546] = "Intruder", [547] = "Primo", [548] = "Cargobob",
    [549] = "Tampa", [550] = "Sunrise", [551] = "Merit", [552] = "Utility", [553] = "Nevada",
    [554] = "Yosemite", [555] = "Windsor", [556] = "Monster A", [557] = "Monster B", [558] = "Jester",
    [559] = "Stratum", [560] = "Sultan", [561] = "Stratum", [562] = "Elegy", [563] = "Raindance",
    [564] = "RC Tiger", [565] = "Flash", [566] = "Tahoma", [567] = "Savanna", [568] = "Bandito",
    [569] = "Freight Flat", [570] = "Streak Carriage", [571] = "Kart", [572] = "Mower", [573] = "Duneride",
    [574] = "Sweeper", [575] = "Broadway", [576] = "Tornado", [577] = "AT-400", [578] = "DFT-30",
    [579] = "Huntley", [580] = "Stafford", [581] = "BF-400", [582] = "Newsvan", [583] = "Tug",
    [584] = "Trailer 3", [585] = "Emperor", [586] = "Wayfarer", [587] = "Euros", [588] = "Hotdog",
    [589] = "Club", [590] = "Freight Box", [591] = "Trailer 3", [592] = "Andromada", [593] = "Dodo",
    [594] = "RC Cam", [595] = "Launch", [596] = "Police LS", [597] = "Police SF", [598] = "Police LV",
    [599] = "Police Ranger", [600] = "Picador", [601] = "S.W.A.T. Van", [602] = "Alpha", [603] = "Phoenix",
    [604] = "Glendale", [605] = "Sadler", [606] = "Luggage Trailer A", [607] = "Luggage Trailer B",
    [608] = "Stairs Trailer", [609] = "Boxville", [610] = "Farm Plow", [611] = "Utility Trailer"
}

pcall(function()
    ffi.cdef[[
        typedef struct RwV3d { float x; float y; float z; } RwV3d;
        void _ZN4CPed15GetBonePositionER5RwV3djb(void* thiz, RwV3d* point, unsigned int bone, bool calledFromCam);
    ]]
end)

local gta = nil
pcall(function() gta = ffi.load("gta_sa") end)

local function getPedBonePositionSafe(ped, bone)
    if not gta or type(getCharPointer) ~= "function" then return nil end
    local ok, x, y, z = pcall(function()
        local pointer = getCharPointer(ped)
        if not pointer or pointer == 0 then return nil end
        local position = ffi.new("RwV3d[1]")
        gta._ZN4CPed15GetBonePositionER5RwV3djb(ffi.cast("void*", pointer), position, bone, false)
        return tonumber(position[0].x), tonumber(position[0].y), tonumber(position[0].z)
    end)
    if ok then return x, y, z end
    return nil
end

-- deteccao MOB/PC
local platformStats = {}
local afkStats = {}

local function getPlatform(id)
    local p = platformStats[id]
    if p == "Mobile" then return "MOB" elseif p == "PC" then return "PC" end
    return nil
end

if okEv and type(sampev) == "table" then
    function sampev.onUnoccupiedSync(id, data)
        platformStats[id] = "PC"
    end

    function sampev.onPlayerSync(id, data)
        if data.keysData == 160 then platformStats[id] = "PC" end
        if data.specialAction ~= 0 and data.specialAction ~= 1 then platformStats[id] = "PC" end
        if data.leftRightKeys ~= nil then
            if data.leftRightKeys ~= 128 and data.leftRightKeys ~= 65408 then
                platformStats[id] = "Mobile"
            elseif platformStats[id] ~= "Mobile" then
                platformStats[id] = "PC"
            end
        end
        if data.upDownKeys ~= nil then
            if data.upDownKeys ~= 128 and data.upDownKeys ~= 65408 then
                platformStats[id] = "Mobile"
            elseif platformStats[id] ~= "Mobile" then
                platformStats[id] = "PC"
            end
        end
    end

    function sampev.onVehicleSync(id, vehid, data)
        if data.leftRightKeys ~= 0 then
            if data.leftRightKeys ~= 128 and data.leftRightKeys ~= 65408 then
                platformStats[id] = "Mobile"
            end
        end
    end

    function sampev.onPlayerQuit(id)
        platformStats[id] = nil
        afkStats[id] = nil
        protection.notices[id] = nil
    end
end

-- ANTI SYNC: filtra apenas pacotes recebidos, preservando os callbacks anteriores.
-- Limites amplos para reduzir falsos positivos em mapas personalizados.
do
    local function finite(value, limit)
        local n = tonumber(value)
        return n ~= nil and n == n and math.abs(n) <= limit
    end

    local function validVector(v, limit)
        return v ~= nil and finite(v.x, limit) and finite(v.y, limit) and finite(v.z, limit)
    end

    -- Assinatura da rotina shake.sendOnFootRVN deste arquivo.
    -- Nao bloqueia o jogador: descarta somente cada pacote que corresponde.
    local function isShakePacket(data)
        if data.specialAction ~= 6 or data.animationId ~= 1115 then return false end
        local speed = data.moveSpeed
        local x, y, z = tonumber(speed.x), tonumber(speed.y), tonumber(speed.z)
        return x * x + y * y >= 4 and z >= 0.8 and z <= 1.2
    end

    function protection.record(playerId)
        local id = tonumber(playerId)
        if not id or id < 0 or id > 65535 or id ~= math.floor(id) then return end
        local now = os.time()
        local previous = protection.notices[id]
        -- Um aviso por remetente a cada 10 segundos; os bloqueios continuam.
        if previous and now >= previous and now - previous < 10 then return end
        local nick = "Desconhecido"
        if type(sampGetPlayerNickname) == "function" then
            local ok, name = pcall(sampGetPlayerNickname, id)
            if ok and type(name) == "string" then
                nick = name:gsub("{[%x]+}", ""):gsub("[%c]", ""):sub(1, 24)
            end
        end
        if type(sampAddChatMessage) == "function" then
            local ok = pcall(sampAddChatMessage, string.format(
                "[AYZE ANTI TREMULACAO] Padrao detectado: %s [ID %d]. Pacote bloqueado.", nick, id),
                0xFFFFC45C)
            if ok then protection.notices[id] = now end
        end
    end

    local function install(name, dataIndex, vectors, scalars)
        local previous = sampev[name]
        sampev[name] = function(...)
            if protection.enabled[0] then
                local data = select(dataIndex, ...)
                local senderId = select(1, ...)
                local ok, valid = pcall(function()
                    if data == nil then return false end
                    for field, limit in pairs(vectors) do
                        if not validVector(data[field], limit) then return false end
                    end
                    for field, limit in pairs(scalars or {}) do
                        if not finite(data[field], limit) then return false end
                    end
                    if protection.antiShake[0] and name == "onPlayerSync" and isShakePacket(data) then
                        protection.shakeBlocked = protection.shakeBlocked + 1
                        pcall(protection.record, senderId)
                        return false
                    end
                    return true
                end)
                if not ok or not valid then
                    protection.blocked = protection.blocked + 1
                    return false
                end
            end
            if previous then return previous(...) end
        end
    end

    if okEv and type(sampev) == "table" then
        install("onPlayerSync", 2, {position = 100000, moveSpeed = 1000})
        install("onVehicleSync", 3, {position = 100000, moveSpeed = 1000})
        install("onPassengerSync", 2, {position = 100000})
        install("onUnoccupiedSync", 2,
            {position = 100000, moveSpeed = 1000, turnSpeed = 1000, roll = 10, direction = 10},
            {vehicleHealth = 1e9})
        install("onTrailerSync", 2, {position = 100000, moveSpeed = 1000, turnSpeed = 1000})
        install("onAimSync", 2, {camPos = 100000, camFront = 10}, {aimZ = 10})
        install("onBulletSync", 2, {origin = 100000, target = 100000, center = 100000})
    end
end

-- AFK
local AFK_MS = 12 * 1000
local AFK_MOVE_THRESHOLD = 0.35

local function getGameTimer()
    if type(sampGetGameTimer) == "function" then
        local ok, t = pcall(sampGetGameTimer)
        if ok and type(t) == "number" then return t end
    end
    return os.clock() * 1000
end

local function updateAfkTracking()
    local now = getGameTimer()
    for _, ped in ipairs(getAllChars()) do
        if ped ~= PLAYER_PED and doesCharExist(ped) then
            local found, pid = sampGetPlayerIdByCharHandle(ped)
            if found then
                local x, y, z = getCharCoordinates(ped)
                local d = afkStats[pid]
                if not d then
                    afkStats[pid] = { x = x, y = y, z = z, lastMove = now }
                elseif getDistanceBetweenCoords3d(x, y, z, d.x, d.y, d.z) > AFK_MOVE_THRESHOLD then
                    d.x, d.y, d.z = x, y, z
                    d.lastMove = now
                end
            end
        end
    end
end

local function isPlayerAfk(pid)
    local d = afkStats[pid]
    if not d then return false end
    return (getGameTimer() - d.lastMove) >= AFK_MS
end

-- cores ESP (formato ABGR do imgui)
local COLOR = {
    healthHigh = 0xFF42E878, healthMedium = 0xFFFFC247, healthLow = 0xFFFF4D5E,
    armor = 0xFF58A6FF, skeleton = 0xFFE8ECF5, line = 0xFFFFFFFF,
    text = 0xFFFFFFFF, muted = 0xFFD9DDE8, panel = 0xD5101118,
    afk = 0xFFFF4D4D, pc = 0xFF38B6FF, mob = 0xFFFF914D,
    black = 0xD0000000, white = 0xFFFFFFFF,
}

local function healthColor(h)
    if h > 65 then return COLOR.healthHigh elseif h > 30 then return COLOR.healthMedium end
    return COLOR.healthLow
end

local function drawBox(dl, x, y, w, h, color)
    if w <= 0 or h <= 0 then return end
    dl:AddRectFilled(imgui.ImVec2(x, y), imgui.ImVec2(x + w, y + h), color, 0)
end

local function drawLine(dl, x1, y1, x2, y2, thickness, color)
    dl:AddLine(imgui.ImVec2(x1, y1), imgui.ImVec2(x2, y2), color, thickness)
end

local function textWidth(t) return imgui.CalcTextSize(t).x end

local function drawText(dl, text, x, y, color)
    dl:AddText(imgui.ImVec2(x + 1, y + 1), COLOR.black, text)
    dl:AddText(imgui.ImVec2(x, y), color, text)
end

local function drawCenteredText(dl, text, cx, y, color)
    drawText(dl, text, cx - textWidth(text) / 2, y, color)
end

local function onScreen(x, y, sw, sh)
    return x and y and x > 0 and y > 0 and x < sw and y < sh
end

local function drawCornerBox(dl, left, top, right, bottom, color)
    local w, h = right - left, bottom - top
    local c = math.max(6, math.min(18, math.min(w, h) * 0.22))
    local ol, os_, ls = 0xB0000000, 3.6, 1.8
    drawLine(dl, left - 1, top - 1, left + c + 1, top - 1, os_, ol)
    drawLine(dl, left - 1, top - 1, left - 1, top + c + 1, os_, ol)
    drawLine(dl, right + 1, top - 1, right - c - 1, top - 1, os_, ol)
    drawLine(dl, right + 1, top - 1, right + 1, top + c + 1, os_, ol)
    drawLine(dl, left - 1, bottom + 1, left + c + 1, bottom + 1, os_, ol)
    drawLine(dl, left - 1, bottom + 1, left - 1, bottom - c - 1, os_, ol)
    drawLine(dl, right + 1, bottom + 1, right - c - 1, bottom + 1, os_, ol)
    drawLine(dl, right + 1, bottom + 1, right + 1, bottom - c - 1, os_, ol)
    drawLine(dl, left, top, left + c, top, ls, color)
    drawLine(dl, left, top, left, top + c, ls, color)
    drawLine(dl, right, top, right - c, top, ls, color)
    drawLine(dl, right, top, right, top + c, ls, color)
    drawLine(dl, left, bottom, left + c, bottom, ls, color)
    drawLine(dl, left, bottom, left, bottom - c, ls, color)
    drawLine(dl, right, bottom, right - c, bottom, ls, color)
    drawLine(dl, right, bottom, right, bottom - c, ls, color)
end

local function drawPlayerSkeleton(dl, cx, top, width, height)
    local headY, neckY = top + height * 0.10, top + height * 0.22
    local chestY, hipY = top + height * 0.38, top + height * 0.60
    local kneeY, bottom = top + height * 0.79, top + height
    local sh, hand, leg = width * 0.34, width * 0.48, width * 0.24
    local c = COLOR.skeleton
    drawLine(dl, cx, headY, cx, neckY, 1.2, c)
    drawLine(dl, cx, neckY, cx, hipY, 1.2, c)
    drawLine(dl, cx - sh, chestY, cx + sh, chestY, 1.2, c)
    drawLine(dl, cx - sh, chestY, cx - hand, hipY, 1.2, c)
    drawLine(dl, cx + sh, chestY, cx + hand, hipY, 1.2, c)
    drawLine(dl, cx, hipY, cx - leg, kneeY, 1.2, c)
    drawLine(dl, cx - leg, kneeY, cx - leg * 1.15, bottom, 1.2, c)
    drawLine(dl, cx, hipY, cx + leg, kneeY, 1.2, c)
    drawLine(dl, cx + leg, kneeY, cx + leg * 1.15, bottom, 1.2, c)
end

local function drawPlayerEsp(dl, ped, pid, sw, sh)
    local myX, myY, myZ = getCharCoordinates(PLAYER_PED)
    local x, y, z = getCharCoordinates(ped)
    local distance = getDistanceBetweenCoords3d(myX, myY, myZ, x, y, z)
    if distance > math.min(esp.playerMaxDistance[0], 350) then return end

    local bx, by, bz = getPedBonePositionSafe(ped, 8)
    local headX, headY = convert3DCoordsToScreen(bx or x, by or y, bz or (z + 1.05))
    local footX, footY = convert3DCoordsToScreen(x, y, z - 1.0)
    if not onScreen(headX, headY, sw, sh) or not onScreen(footX, footY, sw, sh) then return end

    local height = math.abs(footY - headY)
    if height < 12 then return end

    local width = height * 0.42
    local cx = (headX + footX) / 2
    local left, right = cx - width / 2, cx + width / 2
    local top, bottom = math.min(headY, footY), math.max(headY, footY)

    local health = 100
    local ok1, sh1 = pcall(sampGetPlayerHealth, pid)
    if ok1 and type(sh1) == "number" then health = sh1 else health = getCharHealth(ped) or 100 end
    health = math.max(0, math.min(100, health))

    local armor = 0
    local ok2, sa = pcall(sampGetPlayerArmor, pid)
    if ok2 and type(sa) == "number" then armor = sa
    elseif type(getCharArmour) == "function" then armor = getCharArmour(ped) or 0 end
    armor = math.max(0, math.min(100, armor))

    if esp.playerLine[0] then
        drawLine(dl, sw / 2, getLineOriginY(sh), cx, bottom, 1.2, COLOR.line)
    end
    if esp.playerSkeleton[0] then
        drawPlayerSkeleton(dl, cx, top, width, height)
    end
    if esp.playerHealth[0] then
        local barX, fill = left - 6, height * health / 100
        drawBox(dl, barX - 1, top - 1, 5, height + 2, COLOR.black)
        drawBox(dl, barX, top, 3, height, 0x70303030)
        drawBox(dl, barX, bottom - fill, 3, fill, healthColor(health))
    end
    if esp.playerArmor[0] then
        local barX, fill = right + 3, height * armor / 100
        drawBox(dl, barX - 1, top - 1, 5, height + 2, COLOR.black)
        drawBox(dl, barX, top, 3, height, 0x70303030)
        if armor > 0 then drawBox(dl, barX, bottom - fill, 3, fill, COLOR.armor) end
    end

    local elements, totalW = {}, 0
    local function add(str, col)
        local w = textWidth(str)
        elements[#elements + 1] = { text = str, color = col, width = w }
        totalW = totalW + w
    end

    if esp.playerName[0] then
        local name = sampGetPlayerNickname(pid)
        if name then add(name, COLOR.text) end
    end
    if esp.playerId[0] then add("[" .. tostring(pid) .. "]", COLOR.text) end
    if esp.playerPlatform[0] then
        local p = getPlatform(pid)
        if p then add("(" .. p .. ")", (p == "MOB") and COLOR.mob or COLOR.pc) end
    end
    if esp.playerAfk[0] and isPlayerAfk(pid) then add("[AFK]", COLOR.afk) end

    if #elements > 0 then
        local space = textWidth(" ")
        totalW = totalW + space * (#elements - 1)
        local textX, textY = cx - totalW / 2, top - 18
        drawBox(dl, textX - 6, textY - 3, totalW + 12, 18, COLOR.panel)
        local curX = textX
        for _, el in ipairs(elements) do
            drawText(dl, el.text, curX, textY, el.color)
            curX = curX + el.width + space
        end
    end

    if esp.playerDistance[0] then
        drawCenteredText(dl, string.format("%.0fm", distance), cx, bottom + 5, COLOR.muted)
    end
end

local function renderPlayers(dl, sw, sh)
    if not esp.playerEnabled[0] then return end
    for _, ped in ipairs(getAllChars()) do
        if ped ~= PLAYER_PED and doesCharExist(ped) and isCharOnScreen(ped) then
            local found, pid = sampGetPlayerIdByCharHandle(ped)
            if found then pcall(drawPlayerEsp, dl, ped, pid, sw, sh) end
        end
    end
end

local vehicleCorners = {
    { 1.25, 2.65, 1.15 }, { 1.25, -2.65, 1.15 }, { -1.25, -2.65, 1.15 }, { -1.25, 2.65, 1.15 },
    { 1.25, 2.65, -0.85 }, { 1.25, -2.65, -0.85 }, { -1.25, -2.65, -0.85 }, { -1.25, 2.65, -0.85 },
}

local function drawVehicleEsp(dl, veh, sw, sh, myX, myY, myZ)
    local x, y, z = getCarCoordinates(veh)
    local distance = getDistanceBetweenCoords3d(myX, myY, myZ, x, y, z)
    if distance > math.min(esp.vehicleMaxDistance[0], 350) then return end

    local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
    local valid = false
    for _, o in ipairs(vehicleCorners) do
        local wx, wy, wz = getOffsetFromCarInWorldCoords(veh, o[1], o[2], o[3])
        local scx, scy = convert3DCoordsToScreen(wx, wy, wz)
        if onScreen(scx, scy, sw, sh) then
            minX, minY = math.min(minX, scx), math.min(minY, scy)
            maxX, maxY = math.max(maxX, scx), math.max(maxY, scy)
            valid = true
        end
    end
    if not valid or maxX <= minX or maxY <= minY then return end

    local width = maxX - minX
    local cx = minX + width / 2
    local health = math.max(0, math.min(1000, getCarHealth(veh) or 0))
    local accent = healthColor(health / 10)

    drawCornerBox(dl, minX, minY, maxX, maxY, accent)

    if esp.vehicleLine[0] then
        drawLine(dl, sw / 2, getLineOriginY(sh), cx, maxY, 1.2, accent)
    end
    if esp.vehicleName[0] then
        local model = getCarModel(veh)
        local found, vid = sampGetVehicleIdByCarHandle(veh)
        local idText = found and ("  #" .. tostring(vid)) or ""
        local label = (vehicleNames[model] or ("Veiculo " .. model)) .. idText
        local tw = textWidth(label)
        local tx, ty = cx - tw / 2, minY - 18
        drawBox(dl, tx - 6, ty - 3, tw + 12, 18, COLOR.panel)
        drawText(dl, label, tx, ty, COLOR.white)
    end
    if esp.vehicleDistance[0] then
        drawCenteredText(dl, string.format("%.0fm  |  %.0f HP", distance, health), cx, maxY + 13, COLOR.muted)
    end
end

local function renderVehicles(dl, sw, sh)
    if not esp.vehicleEnabled[0] then return end
    local myX, myY, myZ = getCharCoordinates(PLAYER_PED)
    for _, veh in ipairs(getAllVehicles()) do
        if doesVehicleExist(veh) and isCarOnScreen(veh) then
            pcall(drawVehicleEsp, dl, veh, sw, sh, myX, myY, myZ)
        end
    end
end

-- overlay (desenha direto no fundo da tela; so roda com a key ativa)
imgui.OnFrame(
    function() return isAuthenticated and (esp.playerEnabled[0] or esp.vehicleEnabled[0]) end,
    function(self)
        self.HideCursor = true
        local ds = imgui.GetIO().DisplaySize
        local dl = imgui.GetBackgroundDrawList()
        renderPlayers(dl, ds.x, ds.y)
        renderVehicles(dl, ds.x, ds.y)
    end
)

-- ============================================================
-- VEHICLE LIST — helpers + acoes
-- ============================================================
local function isPlayerInAnyVehicle()
    return isCharInAnyCar(PLAYER_PED) or isCharInAnyBoat(PLAYER_PED)
        or isCharInAnyHeli(PLAYER_PED) or isCharInAnyPlane(PLAYER_PED)
end

-- sync sender no padrao SAMP (independente de sampfuncs: usa os IDs de prioridade/reliability do raknet)
local function samp_create_sync_data(id, customSender)
    local raknet = require("samp.raknet")
    require("samp.synchronization")
    local info = ({
        player      = { "PlayerSyncData",      207, sampStorePlayerOnfootData    },
        vehicle     = { "VehicleSyncData",     200, sampStorePlayerIncarData     },
        passenger   = { "PassengerSyncData",   211, sampStorePlayerPassengerData },
        aim         = { "AimSyncData",         203, sampStorePlayerAimData       },
        trailer     = { "TrailerSyncData",     210, sampStorePlayerTrailerData   },
        unoccupied  = { "UnoccupiedSyncData",  209, nil                          },
        bullet      = { "BulletSyncData",      206, nil                          },
        spectator   = { "SpectatorSyncData",   212, nil                          },
    })[id]
    if not info then return nil end

    local structName = "struct " .. info[1]
    local data = ffi.new(structName, {})
    local dataPtr = tonumber(ffi.cast("uintptr_t", ffi.new(structName .. "*", data)))
    local sender = customSender == nil and true or customSender

    if sender and info[3] then
        local pid
        if sender == true then
            _, pid = sampGetPlayerIdByCharHandle(PLAYER_PED)
        else
            pid = tonumber(sender)
        end
        info[3](pid, dataPtr)
    end

    return setmetatable({
        send = function()
            local bs = raknetNewBitStream()
            raknetBitStreamWriteInt8(bs, info[2])
            raknetBitStreamWriteBuffer(bs, dataPtr, ffi.sizeof(data))
            raknetSendBitStreamEx(bs, 1, 1, 1)
            raknetDeleteBitStream(bs)
        end
    }, {
        __index    = function(_, k) return data[k] end,
        __newindex = function(_, k, v) data[k] = v end,
    })
end

local function vehActionPull(sampId)
    if isPlayerInAnyVehicle() then return end
    local ok, car = sampGetCarHandleBySampVehicleId(sampId)
    if not ok or not car then return end
    local x, y, z = getCharCoordinates(PLAYER_PED)
    local sync = samp_create_sync_data("vehicle", true)
    if sync then
        sync.position.x, sync.position.y, sync.position.z = x, y, z
        sync.vehicleId = sampId
        sync.send()
    end
    setCarCoordinates(car, x, y, z)
    warpCharIntoCar(PLAYER_PED, car)
    restoreCameraJumpcut()
end

-- Acoes adaptadas do shark_menu_restyle.lua para o veiculo selecionado.
local function vehActionPullExplode(sampId)
    if isPlayerInAnyVehicle() then
        chat("Saia do veiculo antes de puxar e explodir.")
        return
    end
    local ok, car = sampGetCarHandleBySampVehicleId(sampId)
    if not ok or not car or not doesVehicleExist(car) then
        chat("Veiculo indisponivel na area de stream.")
        return
    end
    local x, y, z = getCharCoordinates(PLAYER_PED)
    warpCharIntoCar(PLAYER_PED, car)
    setCharCoordinates(PLAYER_PED, x, y, z)
    local current = storeCarCharIsInNoSave(PLAYER_PED)
    if doesVehicleExist(current) and isSampAvailable() then
        local found, id = sampGetVehicleIdByCarHandle(current)
        if found then
            local sync = samp_create_sync_data("vehicle", true)
            if sync then
                sync.vehicleId = id
                sync.position.x, sync.position.y, sync.position.z = getCarCoordinates(current)
                sync.vehicleHealth = 1
                sync.send()
                setCarHealth(current, 1)
                wait(100)
            end
        end
    end
    if doesCharExist(PLAYER_PED) and isCharInAnyCar(PLAYER_PED) then
        warpCharFromCarToCoord(PLAYER_PED, x, y, z)
    end
    restoreCameraJumpcut()
end

local function vehActionTeleport(sampId)
    local ok, car = sampGetCarHandleBySampVehicleId(sampId)
    if not ok or not car or not doesVehicleExist(car) then
        chat("Veiculo indisponivel na area de stream.")
        return
    end
    if isCharInAnyCar(PLAYER_PED) then
        taskLeaveAnyCar(PLAYER_PED)
        wait(200)
    end
    -- Revalida depois da espera: o veiculo pode ter saido do stream.
    ok, car = sampGetCarHandleBySampVehicleId(sampId)
    if not ok or not car or not doesVehicleExist(car) then
        chat("O veiculo saiu da area de stream.")
        return
    end
    if isCharInAnyCar(PLAYER_PED) then
        chat("Aguarde sair do veiculo e tente novamente.")
        return
    end
    local x, y, z = getCarCoordinates(car)
    setCharCoordinates(PLAYER_PED, x + 1.5, y + 1.5, z)
    restoreCameraJumpcut()
end

local function runVehicleAction(action)
    if vehlist.actionBusy then return end
    local id = vehlist.selected
    if id == -1 then chat("Selecione um veiculo primeiro."); return end
    vehlist.actionBusy = true
    lua_thread.create(function()
        local ok, err = pcall(action, id)
        vehlist.actionBusy = false
        if not ok then
            chat("Nao foi possivel concluir a acao do veiculo.")
            print("[AYZE VEICULO] " .. tostring(err))
        end
    end)
end

local DELETE_VEHICLE = {
    busy = false,        -- trava anti-reentrada
    ticks = 30,          -- quantos fake syncs mandar antes do destroy
    tickDelay = 35,      -- ms entre cada fake sync
    selectRadius = 125.0 -- raio em pixels pra achar veículo pela mira
}

-- ============================================================
-- DESTROY SILENCIOSO
-- Cria um VehicleSync "fantasma" na posição do player, manda pro servidor
-- e logo em seguida envia DestroyVehicle(vehId). O fake sync garante que
-- o servidor processe o destroy como se fosse uma sync legítima sua.
-- ============================================================
local function sendFakeVehicleSyncSilent(vehId)
    local px, py, pz = getCharCoordinates(PLAYER_PED)
    local data = allocateMemory(59)

    if not data then
        return false
    end

    setStructElement(data, 0, 2, vehId, false)   -- vehicleId
    setStructElement(data, 2, 2, 0, false)
    setStructElement(data, 4, 2, 0, false)
    setStructElement(data, 6, 2, 0, false)
    setStructFloatElement(data, 8, 0, false)     -- roll
    setStructFloatElement(data, 12, 0, false)    -- direction
    setStructFloatElement(data, 16, 0, false)
    setStructFloatElement(data, 20, 0, false)
    setStructFloatElement(data, 24, px, false)   -- position
    setStructFloatElement(data, 28, py, false)
    setStructFloatElement(data, 32, pz, false)
    setStructFloatElement(data, 36, 0, false)    -- moveSpeed
    setStructFloatElement(data, 40, 0, false)
    setStructFloatElement(data, 44, 0, false)    -- turnSpeed
    setStructFloatElement(data, 48, 0, false)
    setStructElement(data, 52, 1, 100, false)    -- health
    setStructElement(data, 53, 1, 0, false)
    setStructElement(data, 54, 1, 0, false)
    setStructElement(data, 55, 1, 0, false)
    setStructElement(data, 56, 1, 0, false)
    setStructElement(data, 57, 2, 0, false)

    sampSendIncarData(data)
    freeMemory(data)
    sampSendVehicleDestroyed(vehId)
    return true
end

-- ============================================================
-- DELETE POR ID
-- ============================================================
local function deleteVehicleById(vehId)
    if not vehId or DELETE_VEHICLE.busy then
        return false
    end

    DELETE_VEHICLE.busy = true

    lua_thread.create(function()
        for i = 1, DELETE_VEHICLE.ticks do
            sendFakeVehicleSyncSilent(vehId)
            wait(DELETE_VEHICLE.tickDelay)
        end
        DELETE_VEHICLE.busy = false
    end)

    return true
end

-- ============================================================
-- ACHAR VEÍCULO NA MIRA
-- Traça um cone a partir do centro da tela e pega o veículo mais próximo
-- do crosshair. Filtra por on-screen + à frente da câmera.
-- ============================================================
local function pointInFront(x, y, z)
    if type(getActiveCameraCoordinates) ~= 'function'
        or type(getActiveCameraPointAt) ~= 'function'
    then
        return true
    end

    local okCam, cx, cy, cz = pcall(getActiveCameraCoordinates)
    local okAt,  ax, ay, az = pcall(getActiveCameraPointAt)

    if not okCam or not okAt
        or type(cx) ~= 'number' or type(cy) ~= 'number' or type(cz) ~= 'number'
        or type(ax) ~= 'number' or type(ay) ~= 'number' or type(az) ~= 'number'
    then
        return true
    end

    local fx, fy, fz = ax - cx, ay - cy, az - cz
    local vx, vy, vz = x  - cx, y  - cy, z  - cz
    return (fx * vx + fy * vy + fz * vz) > 0.0
end

local function findVehicleInCrosshair(radius)
    if type(getAllVehicles) ~= 'function' then
        return nil
    end

    local sw, sh = getScreenResolution()
    local cx, cy = sw * 0.5, sh * 0.5
    local r  = radius or DELETE_VEHICLE.selectRadius
    local bestScore = r * r
    local best = nil

    -- Não permite deletar o próprio veículo
    local myVehicle = 0
    if isCharInAnyCar(PLAYER_PED) then
        myVehicle = storeCarCharIsInNoSave(PLAYER_PED)
    end

    for _, veh in ipairs(getAllVehicles()) do
        if veh and veh ~= 0 and veh ~= myVehicle and doesVehicleExist(veh) then
            local okId, found, id = pcall(sampGetVehicleIdByCarHandle, veh)
            if okId and found and id ~= nil then
                local x, y, z = getCarCoordinates(veh)
                if x and y and z and pointInFront(x, y, z + 0.55) then
                    local sx, sy = convert3DCoordsToScreen(x, y, z + 0.55)
                    if sx and sy and sx >= 0 and sy >= 0 and sx <= sw and sy <= sh then
                        local dx, dy = sx - cx, sy - cy
                        local score = dx * dx + dy * dy
                        if score <= bestScore then
                            bestScore = score
                            best = { handle = veh, id = tonumber(id) }
                        end
                    end
                end
            end
        end
    end

    return best
end

-- Acionado pela chavinha e pelo atalho existentes no menu.
vehlist.delete = function()
    if DELETE_VEHICLE.busy then return end
    local target = findVehicleInCrosshair()
    if target then
        if deleteVehicleById(target.id) then
            printStringNow(
                ('~b~Delete enviado: veiculo #%d'):format(target.id),
                2000
            )
        end
    else
        printStringNow('~r~Nenhum veiculo na mira', 1500)
    end
end

-- ============================================================
-- LAYOUT DO MENU (coordenadas de referencia; tudo multiplicado por S)
-- ============================================================
local CHILD_FLAGS = imgui.WindowFlags.NoScrollbar + imgui.WindowFlags.NoScrollWithMouse
local lastDrawnTab = 0

-- texto centralizado verticalmente na linha cy
local function textAt(x, cy, col, text)
    imgui.SetCursorPos(imgui.ImVec2(x * S, cy * S - imgui.GetTextLineHeight() / 2))
    imgui.TextColored(col, text)
end

-- card com faixa lateral colorida
local function beginCard(id, y, h, stripeH)
    imgui.SetCursorPos(V(CARD_X, y))
    imgui.PushStyleColor(imgui.Col.ChildBg, C.card)
    imgui.PushStyleColor(imgui.Col.Border, C.border)
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, V(0, 0))
    imgui.BeginChild(id, V(CARD_W, h), true, CHILD_FLAGS)
    local p = imgui.GetWindowPos()
    imgui.GetWindowDrawList():AddRectFilled(P(p, 0, 14), P(p, 3, 14 + stripeH), u32(C.blue), 2 * S)
end

local function endCard()
    imgui.EndChild()
    imgui.PopStyleVar()
    imgui.PopStyleColor(2)
end

-- linhas "ROTULO ........ valor" (pitch 22px, valor na coluna 188)
local function cardRows(rows)
    for i, r in ipairs(rows) do
        local cy = 23 + (i - 1) * 22
        textAt(18, cy, C.dim, r[1])
        textAt(188, cy, r[3] or C.text, r[2])
    end
end

local function featureCard(id, y, title, items)
    local h = 56 + #items * 30
    beginCard(id, y, h, 24)
    textAt(18, 23, C.text, title)
    for i, it in ipairs(items) do
        imgui.SetCursorPos(V(18, 44 + (i - 1) * 30))
        imgui.Checkbox(it[1] .. "##" .. id .. i, it[2])
    end
    endCard()
    return y + h + CARD_GAP
end


-- ------------------------------------------------------------
-- ABA VISUAL (cards ESP PLAYER / ESP VEICULO)
-- ------------------------------------------------------------
local espOpen = { player = false, vehicle = false }   -- opcoes minimizadas por padrao

-- chave liga/desliga (estilo iOS)
local function drawSwitch(dl, p, w, h, on, hov)
    local r = (h / 2) * S
    local track = on and (hov and C.blueH or C.blue) or (hov and C.border or C.panel3)
    dl:AddRectFilled(p, P(p, w, h), u32(track), r)
    local kx = on and (p.x + (w - h / 2) * S) or (p.x + (h / 2) * S)
    dl:AddCircleFilled(imgui.ImVec2(kx, p.y + r), r - 3 * S, u32(on and C.text or C.dim), 20)
end

-- icone do cartao (jogador / carro) dentro do emblema
local function drawEspIcon(dl, p, kind, on)
    local bg = on and C.blue or C.panel2
    dl:AddRectFilled(p, P(p, 40, 40), u32(bg), 11 * S)
    local col = u32(on and C.text or C.dim)
    local cx, cy = p.x + 20 * S, p.y + 20 * S
    if kind == "protection" then
        -- Escudo no mesmo emblema e com as mesmas cores dos ESPs.
        local points = { {20, 8}, {30, 12}, {29, 24}, {25, 30},
            {20, 33}, {15, 30}, {11, 24}, {10, 12}, {20, 8} }
        for i = 1, #points - 1 do
            dl:AddLine(P(p, points[i][1], points[i][2]),
                P(p, points[i + 1][1], points[i + 1][2]), col, 2 * S)
        end
        dl:AddLine(P(p, 15, 20), P(p, 19, 24), col, 2 * S)
        dl:AddLine(P(p, 19, 24), P(p, 26, 16), col, 2 * S)
    elseif kind == "keyboard" then
        dl:AddRect(P(p, 6, 11), P(p, 34, 29), col, 3 * S, 0, 2 * S)
        for row = 0, 1 do
            for key = 0, 4 do
                dl:AddRectFilled(P(p, 10 + key * 4.5, 15 + row * 5),
                    P(p, 12 + key * 4.5, 17 + row * 5), col, 0)
            end
        end
        dl:AddLine(P(p, 14, 25), P(p, 26, 25), col, 2 * S)
    elseif kind == "announcement" then
        dl:AddLine(P(p, 10, 16), P(p, 27, 9), col, 2 * S)
        dl:AddLine(P(p, 27, 9), P(p, 27, 29), col, 2 * S)
        dl:AddLine(P(p, 27, 29), P(p, 10, 22), col, 2 * S)
        dl:AddLine(P(p, 10, 22), P(p, 10, 16), col, 2 * S)
        dl:AddLine(P(p, 14, 24), P(p, 17, 32), col, 3 * S)
        dl:AddLine(P(p, 31, 15), P(p, 35, 13), col, 2 * S)
        dl:AddLine(P(p, 31, 23), P(p, 35, 25), col, 2 * S)
    elseif kind == "player" then
        dl:AddCircleFilled(imgui.ImVec2(cx, cy - 6 * S), 5.5 * S, col, 16)
        dl:AddRectFilled(imgui.ImVec2(cx - 9 * S, cy + 1 * S), imgui.ImVec2(cx + 9 * S, cy + 13 * S), col, 6 * S)
    else
        dl:AddRectFilled(imgui.ImVec2(cx - 13 * S, cy - 1 * S), imgui.ImVec2(cx + 13 * S, cy + 7 * S), col, 3 * S)
        dl:AddRectFilled(imgui.ImVec2(cx - 8 * S, cy - 8 * S), imgui.ImVec2(cx + 7 * S, cy - 1 * S), col, 3 * S)
        for _, wx in ipairs({ -7, 7 }) do
            dl:AddCircleFilled(imgui.ImVec2(cx + wx * S, cy + 8 * S), 4 * S, u32(bg), 14)
            dl:AddCircleFilled(imgui.ImVec2(cx + wx * S, cy + 8 * S), 2.5 * S, col, 14)
        end
    end
end

-- seta no cantinho: minimiza / expande
local function collapseButton(id, x, y, open, tipOpen, tipClosed)
    imgui.SetCursorPos(V(x, y))
    local p = imgui.GetCursorScreenPos()
    local clicked = imgui.InvisibleButton("##cb" .. id, V(30, 30))
    local hov = imgui.IsItemHovered()
    local dl = imgui.GetWindowDrawList()
    dl:AddRectFilled(p, P(p, 30, 30), u32(hov and C.panel3 or C.panel2), 9 * S)
    local cx, cy = p.x + 15 * S, p.y + 15 * S
    local col = u32(hov and C.text or C.accent)
    local d = open and -1 or 1
    dl:AddLine(imgui.ImVec2(cx - 5.5 * S, cy - 2.5 * S * d), imgui.ImVec2(cx, cy + 2.5 * S * d), col, 2 * S)
    dl:AddLine(imgui.ImVec2(cx, cy + 2.5 * S * d), imgui.ImVec2(cx + 5.5 * S, cy - 2.5 * S * d), col, 2 * S)
    if hov and not MOBILE then imgui.SetTooltip(open and (tipOpen or "Minimizar") or (tipClosed or "Mostrar opcoes")) end
    return clicked
end

-- botao azul arredondado (mesmo estilo do botao da tecla do menu)
local function pillButton(id, cy, label, active, w)
    imgui.SetCursorPos(V(CARD_W - 18 - (w or 140), cy - 10))
    imgui.PushStyleVarFloat(imgui.StyleVar.FrameRounding, 10 * S)
    imgui.PushStyleVarVec2(imgui.StyleVar.FramePadding, V(8, 3))
    imgui.PushStyleColor(imgui.Col.Button, active and C.blue or C.panel3)
    imgui.PushStyleColor(imgui.Col.ButtonHovered, active and C.blueH or C.border)
    imgui.PushStyleColor(imgui.Col.ButtonActive, C.blueA)
    imgui.PushStyleColor(imgui.Col.Text, active and C.text or C.dim)
    local clicked = imgui.Button(label .. "##" .. id, V(w or 140, 21))
    imgui.PopStyleColor(4)
    imgui.PopStyleVar(2)
    return clicked
end

-- pilula (retangulo + 2 circulos, nao depende de arredondamento do imgui)
local function drawPill(dl, p, w, h, col)
    local r = (h / 2) * S
    dl:AddRectFilled(imgui.ImVec2(p.x + r, p.y), imgui.ImVec2(p.x + w * S - r, p.y + h * S), col)
    dl:AddCircleFilled(imgui.ImVec2(p.x + r, p.y + r), r, col, 28)
    dl:AddCircleFilled(imgui.ImVec2(p.x + w * S - r, p.y + r), r, col, 28)
end

-- chave liga/desliga (bolinha cinza em trilho escuro; azul quando ligada)
local function toggleSwitch(id, x, cy, w, h, ptr)
    imgui.SetCursorPos(V(x, cy - h / 2))
    local p = imgui.GetCursorScreenPos()
    if imgui.InvisibleButton("##ts" .. id, V(w, h)) then ptr[0] = not ptr[0] end
    local hov = imgui.IsItemHovered()
    local on = ptr[0]
    local dl = imgui.GetWindowDrawList()
    local r = (h / 2) * S
    local V4 = imgui.ImVec4

    -- trilho em formato de pilula, sem borda
    if on then
        drawPill(dl, p, w, h, u32(hov and C.blueH or C.blue))
    else
        drawPill(dl, p, w, h, u32(hov and V4(0.26, 0.26, 0.30, 1) or V4(0.20, 0.20, 0.24, 1)))
    end

    local kx = on and (p.x + (w - h / 2) * S) or (p.x + (h / 2) * S)
    local kc = imgui.ImVec2(kx, p.y + r)
    dl:AddCircleFilled(kc, r - 2 * S, u32(on and V4(0.80, 0.84, 1, 1) or V4(0.68, 0.68, 0.72, 1)), 24)
    dl:AddCircleFilled(kc, r - 5 * S, u32(on and V4(1, 1, 1, 1) or V4(0.88, 0.88, 0.91, 1)), 24)
end

-- botao OPCOES no cantinho do card (abre / minimiza as funcoes)
local function optionsButton(id, open)
    local w, h = 100, 28
    imgui.SetCursorPos(V(CARD_W - 18 - w, 20))
    local p = imgui.GetCursorScreenPos()
    local clicked = imgui.InvisibleButton("##opt" .. id, V(w, h))
    local hov = imgui.IsItemHovered()
    local dl = imgui.GetWindowDrawList()
    dl:AddRectFilled(p, P(p, w, h), u32(hov and C.blueH or C.blue), 8 * S)
    dl:AddText(imgui.ImVec2(p.x + 14 * S, p.y + (h / 2) * S - imgui.GetTextLineHeight() / 2), u32(C.text), "OPCOES")
    local cx, cy = p.x + (w - 18) * S, p.y + (h / 2) * S
    local d = open and -1 or 1
    local col = u32(C.text)
    dl:AddLine(imgui.ImVec2(cx - 4.5 * S, cy - 2 * S * d), imgui.ImVec2(cx, cy + 2 * S * d), col, 2 * S)
    dl:AddLine(imgui.ImVec2(cx, cy + 2 * S * d), imgui.ImVec2(cx + 4.5 * S, cy - 2 * S * d), col, 2 * S)
    if hov and not MOBILE then imgui.SetTooltip(open and "Minimizar funcoes" or "Mostrar funcoes") end
    return clicked
end

-- linha "ROTULO ........ [chave]"
local function toggleRow(id, cy, label, ptr)
    textAt(18, cy, ptr[0] and C.text or C.dim, label)
    toggleSwitch(id, CARD_W - 18 - 44, cy, 44, 22, ptr)
end

local function espCard(id, key, y, title, enabledPtr, opts, distPtr)
    local open = espOpen[key]
    local h = open and (94 + (#opts + 1) * 28) or 68
    local on = enabledPtr[0]

    beginCard("##esp_" .. id, y, h, 38)
    local edl = imgui.GetWindowDrawList()
    local ep = imgui.GetWindowPos()

    -- emblema (icone) + nome + estado
    drawEspIcon(edl, P(ep, 18, 14), key, on)
    textAt(70, 26, C.text, title)
    textAt(70, 47, on and C.green or C.dim, on and "ATIVO" or "DESATIVADO")

    -- chave de ativar (ao lado do botao OPCOES)
    toggleSwitch(id .. "on", CARD_W - 18 - 100 - 14 - 44, 34, 44, 22, enabledPtr)

    -- botao OPCOES no cantinho: minimiza / expande as funcoes
    if optionsButton(id, open) then espOpen[key] = not open end

    -- divisoria entre cabecalho e opcoes
    if open then
        edl:AddRectFilled(P(ep, 18, 67), P(ep, CARD_W - 18, 68), u32(C.border))
    end

    if open then
        local cy = 43
        for i, it in ipairs(opts) do
            cy = cy + 28
            toggleRow(id .. i, cy, it[1], it[2])
        end

        -- distancia maxima
        cy = cy + 28
        textAt(18, cy, C.dim, "DISTANCIA MAXIMA")
        imgui.SetCursorPos(V(CARD_W - 18 - 228, cy - 10))
        imgui.PushStyleVarFloat(imgui.StyleVar.FrameRounding, 10 * S)
        imgui.PushStyleVarVec2(imgui.StyleVar.FramePadding, V(8, 3))
        imgui.PushItemWidth(228 * S)
        imgui.SliderInt("##" .. id .. "dist", distPtr, 50, 350, "%d m")
        imgui.PopItemWidth()
        imgui.PopStyleVar(2)

        -- origem da linha (clique para trocar)
        cy = cy + 28
        textAt(18, cy, C.dim, "ORIGEM DA LINHA")
        if pillButton(id .. "lo", cy, lineOriginNames[lineOrigin + 1], true) then
            lineOrigin = (lineOrigin + 1) % 3
        end
    end
    endCard()
    return y + h + CARD_GAP
end

local function drawVisual(y)
    y = espCard("p", "player", y, "ESP PLAYER", esp.playerEnabled, {
        { "NOME", esp.playerName },
        { "ID", esp.playerId },
        { "DISTANCIA", esp.playerDistance },
        { "ESQUELETO", esp.playerSkeleton },
        { "MOB / PC", esp.playerPlatform },
        { "AFK", esp.playerAfk },
        { "LINHA", esp.playerLine },
        { "BARRA DE VIDA", esp.playerHealth },
        { "BARRA DE COLETE", esp.playerArmor },
    }, esp.playerMaxDistance)

    y = espCard("v", "vehicle", y, "ESP VEICULO", esp.vehicleEnabled, {
        { "NOME E ID", esp.vehicleName },
        { "DISTANCIA E HP", esp.vehicleDistance },
        { "LINHA", esp.vehicleLine },
    }, esp.vehicleMaxDistance)
    return y
end

-- ============================================================
-- VEHICLE LIST — render (aba VEICULO)  |  tudo numa caixa so
-- ============================================================
-- botao FILTROS (cantinho da caixa): abre / minimiza busca + distancia + ocupados
vehlist.filtersButton = function(x, open)
    local w, h = 92, 26
    imgui.SetCursorPos(V(x, 13))
    local p = imgui.GetCursorScreenPos()
    local clicked = imgui.InvisibleButton("##vehfilt", V(w, h))
    local hov = imgui.IsItemHovered()
    local dl = imgui.GetWindowDrawList()
    dl:AddRectFilled(p, P(p, w, h), u32(open and (hov and C.blueH or C.blue) or (hov and C.panel3 or C.panel2)), 8 * S)
    local tcol = open and C.text or C.accent
    dl:AddText(imgui.ImVec2(p.x + 13 * S, p.y + (h / 2) * S - imgui.GetTextLineHeight() / 2), u32(tcol), "FILTROS")
    local cx, cy = p.x + (w - 15) * S, p.y + (h / 2) * S
    local d = open and -1 or 1
    dl:AddLine(imgui.ImVec2(cx - 4 * S, cy - 2 * S * d), imgui.ImVec2(cx, cy + 2 * S * d), u32(tcol), 2 * S)
    dl:AddLine(imgui.ImVec2(cx, cy + 2 * S * d), imgui.ImVec2(cx + 4 * S, cy - 2 * S * d), u32(tcol), 2 * S)
    if hov and not MOBILE then imgui.SetTooltip(open and "Minimizar filtros" or "Mostrar filtros") end
    return clicked
end

-- badge LIVRE / OCUPADO
vehlist.badge = function(dl, x, y, occupied)
    local w, h = 66, 18
    local bg, bd, fg = C.greenBg, C.greenBd, C.green
    local txt = "LIVRE"
    if occupied then bg, bd, fg, txt = C.redBg, C.redBd, C.red, "OCUPADO" end
    dl:AddRectFilled(imgui.ImVec2(x, y), imgui.ImVec2(x + w * S, y + h * S), u32(bg), 9 * S)
    dl:AddRect(imgui.ImVec2(x, y), imgui.ImVec2(x + w * S, y + h * S), u32(bd), 9 * S, 0, 1 * S)
    local tw = imgui.CalcTextSize(txt).x
    dl:AddText(imgui.ImVec2(x + (w * S - tw) / 2, y + (h * S - imgui.GetTextLineHeight()) / 2), u32(fg), txt)
end

local function drawVehicleList(y)
    vehlist.maxDist[0] = math.max(50, math.min(2000, vehlist.maxDist[0]))
    local open = vehlist.open
    local fOpen = vehlist.filters and open
    local TOTAL = 468
    local HEAD = 68
    local totalH = open and TOTAL or HEAD

    beginCard("##vehbox", y, totalH, 38)
    local cdl = imgui.GetWindowDrawList()
    local cp = imgui.GetWindowPos()

    -- ---------- cabecalho ----------
    drawEspIcon(cdl, P(cp, 18, 14), "vehicle", open)
    textAt(70, 26, C.text, "PUXAR VEICULO")
    textAt(70, 47, C.dim, "ALCANCE: " .. vehlist.maxDist[0] .. " m")

    if optionsButton("vehbox", open) then vehlist.open = not open end

    if not open then
        endCard()
        return y + totalH + CARD_GAP
    end

    -- divisoria do cabecalho
    cdl:AddRectFilled(P(cp, 18, HEAD - 1), P(cp, CARD_W - 18, HEAD), u32(C.border))

    -- ---------- filtros (minimizaveis) ----------
    textAt(18, HEAD + 22, C.dim, "VEICULOS CARREGADOS PELO SERVIDOR")
    -- Filtros ficam dentro do painel para manter o cabecalho no padrao ESP.
    imgui.SetCursorPos(V(CARD_W - 110, HEAD + 10))
    imgui.PushStyleVarFloat(imgui.StyleVar.FrameRounding, 8 * S)
    imgui.PushStyleColor(imgui.Col.Button, vehlist.filters and C.blue or C.panel2)
    imgui.PushStyleColor(imgui.Col.ButtonHovered, C.panel3)
    imgui.PushStyleColor(imgui.Col.ButtonActive, C.blueA)
    if imgui.Button("FILTROS##vehFilters", V(92, 26)) then
        vehlist.filters = not vehlist.filters
    end
    imgui.PopStyleColor(3)
    imgui.PopStyleVar()
    local listY = HEAD + 48
    if fOpen then
        imgui.PushStyleVarFloat(imgui.StyleVar.FrameRounding, 10 * S)
        imgui.PushStyleVarVec2(imgui.StyleVar.FramePadding, V(12, 5))
        imgui.PushStyleVarFloat(imgui.StyleVar.FrameBorderSize, 1)
        imgui.PushStyleColor(imgui.Col.Border, C.border)

        imgui.SetCursorPos(V(18, HEAD + 48))
        imgui.PushItemWidth((CARD_W - 36) * S)
        imgui.InputTextWithHint("##vehsearch", "Buscar veiculo pelo nome...", vehlist.search, ffi.sizeof(vehlist.search))
        imgui.PopItemWidth()

        local ry = HEAD + 48 + 36
        textAt(18, ry + 12, C.dim, "DISTANCIA")
        imgui.SetCursorPos(V(95, ry))
        imgui.PushItemWidth(180 * S)
        imgui.SliderInt("##vehdist", vehlist.maxDist, 50, 2000, "%d m")
        imgui.PopItemWidth()

        imgui.PopStyleColor()
        imgui.PopStyleVar(3)

        textAt(18, ry + 46, C.dim, "ESCONDER OCUPADOS")
        toggleSwitch("vehhide", CARD_W - 18 - 44, ry + 46, 44, 22, vehlist.hideOccupied)

        listY = ry + 70
    end

    -- ---------- lista ----------
    local actionH = 116
    local listBottom = TOTAL - actionH - 8
    local colY = listY + 8
    textAt(26, colY, C.dim, "NOME")
    textAt(198, colY, C.dim, "ID")
    textAt(262, colY, C.dim, "DIST.")
    textAt(356, colY, C.dim, "STATUS")

    local childTop = listY + 20
    imgui.SetCursorPos(V(18, childTop))
    imgui.PushStyleColor(imgui.Col.ChildBg, C.bg)
    imgui.PushStyleColor(imgui.Col.Border, C.border)
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, V(4, 4))
    imgui.BeginChild("##vehscroll", V(CARD_W - 36, listBottom - childTop), true)
    imgui.PopStyleVar()
    imgui.PopStyleColor(2)

    local myX, myY, myZ = getCharCoordinates(PLAYER_PED)
    local search = ffi.string(vehlist.search):lower()
    local maxDist = math.max(50, math.min(2000, vehlist.maxDist[0]))
    local found = 0
    local rowH = 30
    local dl = imgui.GetWindowDrawList()

    for _, veh in ipairs(getAllVehicles()) do
        if doesVehicleExist(veh) then
            local okV, sampVid = sampGetVehicleIdByCarHandle(veh)
            if okV and type(sampVid) == "number" then
                local model = getCarModel(veh)
                local name = vehicleNames[model] or ("Veiculo " .. model)
                if search == "" or name:lower():find(search, 1, true) then
                    local vx, vy, vz = getCarCoordinates(veh)
                    local dist = getDistanceBetweenCoords3d(myX, myY, myZ, vx, vy, vz)
                    if dist <= maxDist then
                        local driver = getDriverOfCar(veh)
                        local occupied = doesCharExist(driver) and not isCharDead(driver)
                        if not (vehlist.hideOccupied[0] and occupied) then
                            found = found + 1
                            local isSel = vehlist.selected == sampVid
                            if isSel then vehlist.selName = name end
                            if imgui.Selectable("##vh" .. sampVid, isSel, 0, V(CARD_W - 36 - 22, rowH)) then
                                vehlist.selected = sampVid
                                vehlist.selName = name
                            end
                            local mn = imgui.GetItemRectMin()
                            local ty = mn.y + (rowH * S - imgui.GetTextLineHeight()) / 2
                            if isSel then
                                dl:AddRectFilled(P(mn, 0, 4), P(mn, 3, rowH - 4), u32(C.blue), 2 * S)
                            end
                            dl:AddText(imgui.ImVec2(mn.x + 10 * S, ty),  u32(C.text), name:sub(1, 18))
                            dl:AddText(imgui.ImVec2(mn.x + 172 * S, ty), u32(C.dim), "#" .. sampVid)
                            local dcol = dist <= 50 and C.green or (dist <= 150 and C.accent or C.red)
                            dl:AddText(imgui.ImVec2(mn.x + 236 * S, ty), u32(dcol), string.format("%.0fm", dist))
                            vehlist.badge(dl, mn.x + 330 * S, mn.y + ((rowH - 18) / 2) * S, occupied)
                        end
                    end
                end
            end
        end
    end

    if found == 0 then
        imgui.Dummy(V(1, 4))
        imgui.TextColored(C.dim, "   Nenhum veiculo encontrado.")
    end

    imgui.EndChild()

    -- ---------- acao (dentro da mesma caixa) ----------
    local ay = TOTAL - actionH
    cdl:AddRectFilled(P(cp, 18, ay), P(cp, CARD_W - 18, ay + 1), u32(C.border))

    local has = vehlist.selected ~= -1 and not vehlist.actionBusy
    if has then
        local nm = (vehlist.selName ~= "" and vehlist.selName or "Veiculo")
        textAt(18, ay + 16, C.text, "SELECIONADO: " .. nm .. "  #" .. vehlist.selected)
    else
        textAt(18, ay + 16, C.dim, vehlist.actionBusy and "ACAO EM ANDAMENTO..."
            or "Selecione um veiculo na lista acima.")
    end

    imgui.SetCursorPos(V(18, ay + 34))
    imgui.PushStyleVarFloat(imgui.StyleVar.FrameRounding, 10 * S)
    imgui.PushStyleVarVec2(imgui.StyleVar.FramePadding, V(8, 3))
    imgui.PushStyleColor(imgui.Col.Button, has and C.blue or C.panel2)
    imgui.PushStyleColor(imgui.Col.ButtonHovered, has and C.blueH or C.panel2)
    imgui.PushStyleColor(imgui.Col.ButtonActive, has and C.blueA or C.panel2)
    imgui.PushStyleColor(imgui.Col.Text, has and C.text or C.dim)
    local actionW = (CARD_W - 46) / 2
    if imgui.Button("PUXAR VEICULO##vpull", V(actionW, 32)) and has then
        runVehicleAction(vehActionPull)
    end
    imgui.SetCursorPos(V(28 + actionW, ay + 34))
    if imgui.Button("PUXAR E EXPLODIR##vexplode", V(actionW, 32)) and has then
        runVehicleAction(vehActionPullExplode)
    end
    imgui.SetCursorPos(V(18, ay + 74))
    if imgui.Button("TELEPORTAR PARA O VEICULO##vteleport", V(CARD_W - 36, 30)) and has then
        runVehicleAction(vehActionTeleport)
    end
    imgui.PopStyleColor(4)
    imgui.PopStyleVar(2)

    endCard()
    return y + totalH + CARD_GAP
end

-- ============================================================
-- DELETAR VEICULO — card separado (chavinha + tecla de atalho)
-- ============================================================
vehlist.drawDelete = function(y)
    local open = vehlist.delOpen
    local on = vehlist.delEnabled[0]
    local h = open and 94 or 68

    beginCard("##vehdel", y, h, 38)
    local edl = imgui.GetWindowDrawList()
    local ep = imgui.GetWindowPos()

    drawEspIcon(edl, P(ep, 18, 14), "vehicle", on)
    textAt(70, 26, C.text, "DELETAR VEICULO")
    textAt(70, 47, on and C.green or C.dim, on and "ATIVO" or "DESATIVADO")

    toggleSwitch("vdelon", CARD_W - 18 - 100 - 14 - 44, 34, 44, 22, vehlist.delEnabled)
    if optionsButton("vdel", open) then vehlist.delOpen = not open end

    if open then
        edl:AddRectFilled(P(ep, 18, 67), P(ep, CARD_W - 18, 68), u32(C.border))

        -- tecla de atalho (so PC)
        local cy = 71
        textAt(18, cy, C.dim, "TECLA DE ATALHO")
        local lbl = vehlist.bindingDel and "APERTE UMA TECLA..." or keysim.label(vehlist.delKey)
        if pillButton("vdelkey", cy, lbl, vehlist.bindingDel, 160) then
            vehlist.bindingDel = not vehlist.bindingDel
        end
        if imgui.IsItemHovered() and not MOBILE then
            imgui.SetTooltip("Clique e aperte a tecla (ou toque num botao do SIMULADOR). ESC cancela, BACKSPACE remove.")
        end
    end

    endCard()
    return y + h + CARD_GAP
end

-- ============================================================
-- TREMULACAO — card da aba PLAYER (chavinha + tecla de atalho)
-- ============================================================
local function drawShake(y)
    local open = shake.open
    local on = shake.enabled[0]
    local h = open and 94 or 68

    beginCard("##shake", y, h, 38)
    local edl = imgui.GetWindowDrawList()
    local ep = imgui.GetWindowPos()

    drawEspIcon(edl, P(ep, 18, 14), "player", on)
    textAt(70, 26, C.text, "TREMULACAO")
    textAt(70, 47, on and C.green or C.dim, on and "ATIVO" or "DESATIVADO")

    toggleSwitch("shakeon", CARD_W - 18 - 100 - 14 - 44, 34, 44, 22, shake.enabled)
    -- A chave so muda por clique/toque direto, nunca por ativacao do teclado.
    if shake.enabled[0] ~= on and not (imgui.IsItemHovered() and imgui.IsMouseReleased(0)) then
        shake.enabled[0] = on
    end
    if optionsButton("shake", open) then shake.open = not open end

    if open then
        edl:AddRectFilled(P(ep, 18, 67), P(ep, CARD_W - 18, 68), u32(C.border))
        local cy = 71
        textAt(18, cy, C.dim, "TECLA DE ATALHO")
        local lbl = shake.binding and "APERTE UMA TECLA..." or keysim.label(shake.key)
        if pillButton("shakekey", cy, lbl, shake.binding, 160) then
            shake.binding = not shake.binding
        end
        if imgui.IsItemHovered() and not MOBILE then
            imgui.SetTooltip("Clique e aperte a tecla (ou toque num botao do SIMULADOR). ESC cancela, BACKSPACE remove.")
        end
    end

    endCard()
    return y + h + CARD_GAP
end

-- ============================================================
-- GOD MOD — card da aba PLAYER (chavinha)
-- ============================================================
local function drawGod(y)
    local open = god.open
    local en = god.enabled[0]
    local on = godIsOn()
    local h = open and 94 or 68

    beginCard("##god", y, h, 38)
    local edl = imgui.GetWindowDrawList()
    local ep = imgui.GetWindowPos()

    drawEspIcon(edl, P(ep, 18, 14), "player", on)
    textAt(70, 26, C.text, "GOD MOD")
    if on then
        textAt(70, 47, C.green, "ATIVO")
    elseif en then
        textAt(70, 47, C.accent, "AGUARDANDO ATALHO")
    else
        textAt(70, 47, C.dim, "DESATIVADO")
    end

    toggleSwitch("godon", CARD_W - 18 - 100 - 14 - 44, 34, 44, 22, god.enabled)
    -- A chave so muda por clique/toque direto, nunca por tecla do teclado.
    if god.enabled[0] ~= en and not (imgui.IsItemHovered() and imgui.IsMouseReleased(0)) then
        god.enabled[0] = en
    end
    if god.enabled[0] ~= en then god.active = false end   -- religar a chavinha comeca desligado
    if optionsButton("god", open) then god.open = not open end

    if open then
        edl:AddRectFilled(P(ep, 18, 67), P(ep, CARD_W - 18, 68), u32(C.border))
        local cy = 71
        textAt(18, cy, C.dim, "TECLA DE ATALHO")
        local lbl = god.binding and "APERTE UMA TECLA..." or keysim.label(god.key)
        if pillButton("godkey", cy, lbl, god.binding, 160) then
            god.binding = not god.binding
        end
        if imgui.IsItemHovered() and not MOBILE then
            imgui.SetTooltip("Clique e aperte a tecla (ou toque num botao do SIMULADOR). ESC cancela, BACKSPACE remove.")
        end
    end

    endCard()
    return y + h + CARD_GAP
end

local function drawUpside(y)
    local open = upside.open
    local en = upside.enabled[0]
    local on = upsideIsOn()
    local h = open and 94 or 68

    beginCard("##upside", y, h, 38)
    local edl = imgui.GetWindowDrawList()
    local ep = imgui.GetWindowPos()

    drawEspIcon(edl, P(ep, 18, 14), "player", on)
    textAt(70, 26, C.text, "CABECA PARA BAIXO")
    if on then
        textAt(70, 47, C.green, "ATIVO")
    elseif en then
        textAt(70, 47, C.accent, "AGUARDANDO ATALHO")
    else
        textAt(70, 47, C.dim, "DESATIVADO")
    end

    toggleSwitch("upsideon", CARD_W - 18 - 100 - 14 - 44, 34, 44, 22, upside.enabled)
    -- A chave so muda por clique/toque direto, nunca por tecla do teclado.
    if upside.enabled[0] ~= en and not (imgui.IsItemHovered() and imgui.IsMouseReleased(0)) then
        upside.enabled[0] = en
    end
    if upside.enabled[0] ~= en then upside.active = false end   -- religar a chavinha comeca desligado
    if optionsButton("upside", open) then upside.open = not open end

    if open then
        edl:AddRectFilled(P(ep, 18, 67), P(ep, CARD_W - 18, 68), u32(C.border))
        local cy = 71
        textAt(18, cy, C.dim, "TECLA DE ATALHO")
        local lbl = upside.binding and "APERTE UMA TECLA..." or keysim.label(upside.key)
        if pillButton("upsidekey", cy, lbl, upside.binding, 160) then
            upside.binding = not upside.binding
        end
        if imgui.IsItemHovered() and not MOBILE then
            imgui.SetTooltip("Clique e aperte a tecla (ou toque num botao do SIMULADOR). ESC cancela, BACKSPACE remove.")
        end
    end

    endCard()
    return y + h + CARD_GAP
end

local function drawInvisibility(y)
    local open = invisibility.open
    local en = invisibility.enabled[0]
    local on = invisibilityIsOn()
    local h = open and 94 or 68

    beginCard("##invisibility", y, h, 38)
    local edl = imgui.GetWindowDrawList()
    local ep = imgui.GetWindowPos()

    drawEspIcon(edl, P(ep, 18, 14), "player", on)
    textAt(70, 26, C.text, "INVISIBILIDADE")
    if on then
        textAt(70, 47, C.green, "ATIVO")
    else
        textAt(70, 47, C.dim, "DESATIVADO")
    end

    toggleSwitch("invisibilityon", CARD_W - 18 - 100 - 14 - 44, 34, 44, 22, invisibility.enabled)
    -- A chave so muda por clique/toque direto, nunca por tecla do teclado.
    if invisibility.enabled[0] ~= en and not (imgui.IsItemHovered() and imgui.IsMouseReleased(0)) then
        invisibility.enabled[0] = en
    end
    if optionsButton("invisibility", open) then invisibility.open = not open end

    if open then
        edl:AddRectFilled(P(ep, 18, 67), P(ep, CARD_W - 18, 68), u32(C.border))
        local cy = 71
        textAt(18, cy, C.dim, "TECLA DE ATALHO")
        local lbl = invisibility.binding and "APERTE UMA TECLA..." or keysim.label(invisibility.key)
        if pillButton("invisibilitykey", cy, lbl, invisibility.binding, 160) then
            invisibility.binding = not invisibility.binding
        end
        if imgui.IsItemHovered() and not MOBILE then
            imgui.SetTooltip("Clique e aperte a tecla (ou toque num botao do SIMULADOR). ESC cancela, BACKSPACE remove.")
        end
    end

    endCard()
    return y + h + CARD_GAP
end

-- ------------------------------------------------------------
-- BARRA LATERAL
-- ------------------------------------------------------------
local function drawSidebar()
    local dl = imgui.GetWindowDrawList()
    local wp = imgui.GetWindowPos()

    -- fundo da barra (arredondado so no lado esquerdo)
    dl:AddRectFilled(P(wp, 1, 1), P(wp, SIDE_W, H_MAIN - 1), u32(C.side), 12 * S)
    dl:AddRectFilled(P(wp, 100, 1), P(wp, SIDE_W, H_MAIN - 1), u32(C.side), 0)

    -- titulo
    imgui.SetWindowFontScale(1.6)
    textAt(23, 39, C.text, "AYZE")
    imgui.SetWindowFontScale(1.0)
    textAt(23, 66, C.accent, "MENU PREMIUM")
    local lp = P(wp, 23, 90)
    dl:AddRectFilledMultiColor(lp, P(lp, 172, 2), u32(C.blue), u32(C.side), u32(C.side), u32(C.blue))

    -- abas (altura 40, passo 56)
    local lh = imgui.GetTextLineHeight()
    for i, name in ipairs(TABS) do
        local top = 111 + (i - 1) * 56
        local p = P(wp, 10, top)
        imgui.SetCursorPos(V(10, top))
        imgui.InvisibleButton("##tab" .. i, V(209, 40))
        local hovered = imgui.IsItemHovered()
        if imgui.IsItemClicked() then
            if i == 2 and selectedTab == 2 then visualSub = 0 end
            selectedTab = i
        end
        local sel = (selectedTab == i)

        if sel or hovered then
            dl:AddRectFilled(p, P(p, 209, 40), u32(sel and C.panel2 or C.card), 8 * S)
        end
        if sel then
            dl:AddRectFilled(P(p, 0, 9), P(p, 3, 31), u32(C.blue), 2 * S)
        end
        dl:AddCircleFilled(P(p, 20, 20), 3.5 * S, u32(sel and C.accent or C.dim), 12)
        dl:AddText(imgui.ImVec2(p.x + 31 * S, p.y + 20 * S - lh / 2), u32(sel and C.text or C.dim), name)
    end

    -- cartao "logado como" (209x81, colado no rodape)
    imgui.SetCursorPos(V(10, 407))
    imgui.PushStyleColor(imgui.Col.ChildBg, C.card)
    imgui.PushStyleColor(imgui.Col.Border, C.border)
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, V(0, 0))
    imgui.BeginChild("##userbox", V(209, 81), true, CHILD_FLAGS)
    local up = imgui.GetWindowPos()
    imgui.GetWindowDrawList():AddCircleFilled(P(up, 195, 16), 4 * S, u32(C.green), 12)
    textAt(16, 18, C.dim, "LOGADO COMO")
    textAt(16, 40, C.text, userName)
    textAt(16, 62, C.dim, "Expira:")
    textAt(16 + imgui.CalcTextSize("Expira:").x / S + 8, 62, C.accent, expiresText)
    imgui.EndChild()
    imgui.PopStyleVar()
    imgui.PopStyleColor(2)
end

-- ------------------------------------------------------------
-- CONTEUDO
-- ------------------------------------------------------------
local function drawContent()
    if lastDrawnTab ~= selectedTab then
        imgui.SetScrollY(0)
        lastDrawnTab = selectedTab
    end

    -- mobile: rolagem arrastando o dedo no conteudo (fora de botoes/campos)
    if MOBILE and imgui.IsWindowHovered(imgui.HoveredFlags.ChildWindows)
        and imgui.IsMouseDragging(0, 6 * S) and not imgui.IsAnyItemActive() then
        imgui.SetScrollY(imgui.GetScrollY() - imgui.GetIO().MouseDelta.y)
    end

    local y = 17

    if selectedTab == 1 then
        local protectionOpen = protection.open
        local protectionHeight = protectionOpen and 236 or 68
        local available = okEv and type(sampev) == "table"
        if not available then protection.enabled[0] = false end
        local on = protection.enabled[0]
        beginCard("##protection", y, protectionHeight, 38)
        local pdl = imgui.GetWindowDrawList()
        local pp = imgui.GetWindowPos()
        drawEspIcon(pdl, P(pp, 18, 14), "protection", on)
        textAt(70, 26, C.text, "PROTECAO")
        textAt(70, 47, on and C.green or C.dim,
            not available and "INDISPONIVEL" or (on and "ATIVO" or "DESATIVADO"))
        if available then
            toggleSwitch("protectionOn", CARD_W - 18 - 100 - 14 - 44, 34, 44, 22, protection.enabled)
        else
            drawSwitch(pdl, P(pp, CARD_W - 18 - 100 - 14 - 44, 23), 44, 22, false, false)
        end
        if optionsButton("protection", protectionOpen) then protection.open = not protectionOpen end
        if protectionOpen then
            pdl:AddRectFilled(P(pp, 18, 67), P(pp, CARD_W - 18, 68), u32(C.border))
            toggleRow("protectionAntiShake", 92, "ANTI TREMULACAO", protection.antiShake)
            textAt(18, 123, C.dim, "Anti Sync: filtra pacotes e permite movimentos normais.")
            textAt(18, 148, C.dim, "Deteccoes no seu chat: nome e ID, sem spam.")
            textAt(18, 181, C.dim, "Tremulacao bloqueada: " .. protection.shakeBlocked)
            textAt(18, 211, C.dim, "Total de bloqueios: " .. protection.blocked)
            if pillButton("antiSyncReset", 211, "ZERAR", false, 100) then
                protection.blocked = 0
                protection.shakeBlocked = 0
            end
        end
        endCard()
        y = y + protectionHeight + CARD_GAP

        -- Simulador no mesmo padrao dos cards ESP.
        do
            local open = keysim.cardOpen
            local h = open and 186 or 68
            local on = keysim.visible[0]
            beginCard("##keysim", y, h, 38)
            local dl, p = imgui.GetWindowDrawList(), imgui.GetWindowPos()
            drawEspIcon(dl, P(p, 18, 14), "keyboard", on)
            textAt(70, 26, C.text, "SIMULADOR DE TECLAS")
            textAt(70, 47, on and C.green or C.dim, on and "BOTOES VISIVEIS" or "BOTOES OCULTOS")
            toggleSwitch("ksvis", CARD_W - 18 - 100 - 14 - 44, 34, 44, 22, keysim.visible)
            if keysim.visible[0] ~= on then keysim.save() end
            if optionsButton("keysim", open) then keysim.cardOpen = not open end
            if open then
                dl:AddRectFilled(P(p, 18, 67), P(p, CARD_W - 18, 68), u32(C.border))
                textAt(18, 90, C.dim, "Crie botoes na tela para usar os atalhos no mobile.")
                textAt(18, 116, C.dim, "BOTOES CRIADOS: " .. #keysim.buttons)
                imgui.SetCursorPos(V(18, 140))
                imgui.PushStyleVarFloat(imgui.StyleVar.FrameRounding, 10 * S)
                imgui.PushStyleColor(imgui.Col.Button, C.blue)
                imgui.PushStyleColor(imgui.Col.ButtonHovered, C.blueH)
                imgui.PushStyleColor(imgui.Col.ButtonActive, C.blueA)
                if imgui.Button("ABRIR SIMULADOR##ksopen", V(CARD_W - 36, 30)) then
                    keysim.pickerOpen[0] = true
                end
                imgui.PopStyleColor(3)
                imgui.PopStyleVar()
            end
            endCard()
            y = y + h + CARD_GAP
        end

        do
            local open = autoDiv.open
            local h = open and 244 or 68
            local on = autoDiv.active
            beginCard("##autodiv", y, h, 38)
            local dl, p = imgui.GetWindowDrawList(), imgui.GetWindowPos()
            drawEspIcon(dl, P(p, 18, 14), "announcement", on)
            textAt(70, 26, C.text, "AUTO DIVULGACAO")
            textAt(70, 47, on and C.green or C.dim, on and "ATIVO" or "DESATIVADO")
            autoDiv.uiActive[0] = on
            toggleSwitch("autoDivOn", CARD_W - 18 - 100 - 14 - 44, 34, 44, 22, autoDiv.uiActive)
            if autoDiv.uiActive[0] ~= on then
                if on then
                    autoDiv.active = false
                    autoDiv.status = "PARADO"
                elseif ffi.string(autoDiv.message):match("%S") then
                    autoDiv.active = true
                    autoDiv.elapsed = autoDiv.interval[0] * 1000
                    autoDiv.status = "ATIVO"
                else
                    autoDiv.uiActive[0] = false
                    autoDiv.status = "DIGITE UMA MENSAGEM PRIMEIRO"
                    autoDiv.open = true
                end
            end
            if optionsButton("autoDiv", open) then autoDiv.open = not open end
            if open then
                dl:AddRectFilled(P(p, 18, 67), P(p, CARD_W - 18, 68), u32(C.border))
                textAt(18, 88, C.dim, "MENSAGEM PARA O CHAT")
                imgui.PushStyleVarFloat(imgui.StyleVar.FrameRounding, 8 * S)
                imgui.PushStyleVarVec2(imgui.StyleVar.FramePadding, V(10, 6))
                imgui.PushItemWidth((CARD_W - 36) * S)
                imgui.SetCursorPos(V(18, 103))
                imgui.InputTextWithHint("##autodivmsg", "Digite a mensagem...", autoDiv.message, ffi.sizeof(autoDiv.message))
                textAt(18, 149, C.dim, "INTERVALO ENTRE MENSAGENS")
                imgui.SetCursorPos(V(18, 165))
                imgui.SliderInt("##autodivinterval", autoDiv.interval, 1, 300, "%d segundos")
                imgui.PopItemWidth()
                imgui.PopStyleVar(2)
                autoDiv.interval[0] = math.max(1, math.min(300, autoDiv.interval[0]))
                textAt(18, 218, autoDiv.active and C.green or C.dim, autoDiv.status)
            end
            endCard()
            y = y + h + CARD_GAP
        end

    elseif selectedTab == 2 then
        y = drawVisual(y)

    elseif selectedTab == 3 then
        y = drawVehicleList(y)
        y = vehlist.drawDelete(y)

    elseif selectedTab == 4 then
        y = drawGod(y)
        y = drawUpside(y)
        y = drawShake(y)
        y = drawInvisibility(y)

    elseif selectedTab == 5 then
        -- Configuracao de funcoes: acao principal em destaque e retorno separado.
        beginCard("##saveFunctions", y, 230, 44)
        textAt(20, 23, C.accent, "PREFERENCIAS")
        textAt(20, 48, C.text, "SALVAR FUNCOES DO MENU")
        textAt(20, 73, C.dim, "Escolha como iniciar o menu no proximo login.")

        local buttonW = (CARD_W - 52) / 2
        imgui.PushStyleVarFloat(imgui.StyleVar.FrameRounding, 9 * S)
        imgui.PushStyleColor(imgui.Col.Button, C.blue)
        imgui.PushStyleColor(imgui.Col.ButtonHovered, C.blueH)
        imgui.PushStyleColor(imgui.Col.ButtonActive, C.blueA)
        imgui.SetCursorPos(V(20, 96))
        if imgui.Button("SALVAR FUNCOES##saveFunctions", V(buttonW, 40)) then
            functionStore.write(true)
        end
        imgui.PopStyleColor(3)

        imgui.PushStyleColor(imgui.Col.Button, C.panel2)
        imgui.PushStyleColor(imgui.Col.ButtonHovered, C.panel3)
        imgui.PushStyleColor(imgui.Col.ButtonActive, C.border)
        imgui.SetCursorPos(V(32 + buttonW, 96))
        if imgui.Button("NAO SALVAR##forgetFunctions", V(buttonW, 40)) then
            functionStore.write(false)
        end
        imgui.PopStyleColor(3)
        imgui.PopStyleVar()
        textAt(20, 151, C.dim, "Restaura o estado salvo.")
        textAt(32 + buttonW, 151, C.dim, "Mantem apenas esta sessao.")

        local sp = imgui.GetWindowPos()
        imgui.GetWindowDrawList():AddRectFilled(P(sp, 18, 176),
            P(sp, CARD_W - 18, 214), u32(C.panel2), 8 * S)
        imgui.GetWindowDrawList():AddCircleFilled(P(sp, 31, 195),
            3 * S, u32(C.accent), 12)
        -- Quebra automatica para mensagens de status longas no mobile.
        imgui.SetCursorPos(V(43, 181))
        imgui.PushTextWrapPos((CARD_W - 28) * S)
        imgui.TextColored(C.dim, functionStore.status)
        imgui.PopTextWrapPos()
        endCard()
        y = y + 230 + CARD_GAP

        -- informacoes
        beginCard("##info", y, 109, 24)
        cardRows({
            { "VERSAO DO MENU", "v" .. SCRIPT_VERSION .. (MOBILE and " (mobile)" or "") },
            { "COMANDO", "/" .. OPEN_COMMAND },
            { "STATUS", "Licenca ativa", C.green },
        })
        endCard()
        y = y + 109 + CARD_GAP

        if MOBILE then
            -- como abrir o menu no mobile
            beginCard("##hotkey", y, 94, 38)
            textAt(18, 23, C.text, "Como abrir o menu")
            textAt(18, 45, C.dim, "Botao flutuante (arraste para mover) ou /" .. OPEN_COMMAND)
            imgui.PushStyleColor(imgui.Col.Button, C.blueA)
            imgui.PushStyleColor(imgui.Col.ButtonHovered, C.blue)
            imgui.SetCursorPos(V(18, 59))
            if imgui.Button("FECHAR MENU##closem", V(170, 26)) then
                showMainMenu[0] = false
            end
            imgui.PopStyleColor(2)
            endCard()
        else
            -- teclas de atalho (PC)
            beginCard("##hotkey", y, 94, 38)
            textAt(18, 23, C.text, "Teclas de atalho")
            textAt(18, 45, C.dim, "Clique no botao e aperte a tecla. ESC cancela.")
            textAt(18, 71, C.dim, "TECLA DO MENU")
            imgui.PushStyleVarVec2(imgui.StyleVar.FramePadding, V(8, 3))
            imgui.PushStyleColor(imgui.Col.Button, C.blueA)
            imgui.PushStyleColor(imgui.Col.ButtonHovered, C.blue)
            imgui.SetCursorPos(V(188, 61))
            if imgui.Button((bindingKey and "APERTE UMA TECLA..." or keyName(hotkey)) .. "##bind", V(140, 21)) then
                bindingKey = true
            end
            imgui.SetCursorPos(V(336, 61))
            if imgui.Button("LIMPAR##clr", V(80, 21)) then
                hotkey = 0
                bindingKey = false
                saveConfig()
            end
            imgui.PopStyleColor(2)
            imgui.PopStyleVar()
            endCard()
        end
        y = y + 94 + CARD_GAP

        -- cor do menu
        beginCard("##cor", y, 206, 38)
        textAt(18, 23, C.text, "Cor do menu")
        textAt(18, 45, C.dim, "Escolha uma cor pronta ou crie a sua. Fica salva.")
        for i, pr in ipairs(PRESETS) do
            local col, row = (i - 1) % 4, math.floor((i - 1) / 4)
            local pc = { pr[2], pr[3], pr[4] }
            imgui.SetCursorPos(V(18 + col * 120, 69 + row * 40))
            imgui.PushStyleColor(imgui.Col.Button, rgb(pc[1], pc[2], pc[3]))
            imgui.PushStyleColor(imgui.Col.ButtonHovered, shade(pc, 0.15))
            imgui.PushStyleColor(imgui.Col.ButtonActive, shade(pc, -0.2))
            if imgui.Button(pr[1] .. "##pr" .. i, V(112, 31)) then
                applyColor(pr[2], pr[3], pr[4])
            end
            imgui.PopStyleColor(3)
        end
        textAt(18, 168, C.dim, "COR PERSONALIZADA")

        -- botao que abre o seletor de cor (roda + ponteiro arrastavel)
        imgui.SetCursorPos(V(188, 153))
        imgui.PushStyleVarVec2(imgui.StyleVar.FramePadding, V(8, 3))
        if imgui.Button("AJUSTAR COR##pick", V(150, 31)) then
            pickCol[0], pickCol[1], pickCol[2] = cr[0] / 255, cg[0] / 255, cb[0] / 255
            imgui.OpenPopup("##ayze_picker")
        end
        imgui.PopStyleVar()

        -- previa da cor atual
        imgui.SetCursorPos(V(348, 153))
        local sp = imgui.GetCursorScreenPos()
        imgui.GetWindowDrawList():AddRectFilled(sp, P(sp, 31, 31), u32(rgb(cr[0], cg[0], cb[0])), 8 * S)
        imgui.Dummy(V(31, 31))

        -- janela do seletor de cor
        imgui.PushStyleColor(imgui.Col.PopupBg, C.card)
        imgui.PushStyleColor(imgui.Col.Border, C.blueA)
        imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, V(16, 16))
        if imgui.BeginPopup("##ayze_picker") then
            imgui.TextColored(C.text, "Ajustar cor do menu")
            imgui.TextColored(C.dim, "Arraste o ponteiro para escolher.")
            imgui.Dummy(V(0, 4))
            imgui.PushItemWidth(210 * S)
            local flags = imgui.ColorEditFlags.PickerHueWheel + imgui.ColorEditFlags.NoAlpha
            if imgui.ColorPicker3("##ayze_cp", pickCol, flags) then
                applyColor(
                    clamp(pickCol[0] * 255),
                    clamp(pickCol[1] * 255),
                    clamp(pickCol[2] * 255)
                )
            end
            imgui.PopItemWidth()
            imgui.Dummy(V(0, 4))
            if imgui.Button("PRONTO##pickok", imgui.ImVec2(-1, 30 * S)) then
                imgui.CloseCurrentPopup()
            end
            imgui.EndPopup()
        end
        imgui.PopStyleVar()
        imgui.PopStyleColor(2)
        endCard()
        y = y + 206 + CARD_GAP

        -- conta
        beginCard("##conta", y, 112, 24)
        textAt(18, 23, C.text, "Conta")
        textAt(18, 48, C.dim, "HWID  " .. HWID)
        imgui.PushStyleColor(imgui.Col.Button, C.redBd)
        imgui.PushStyleColor(imgui.Col.ButtonHovered, C.red)
        imgui.PushStyleColor(imgui.Col.ButtonActive, C.redBg)
        imgui.SetCursorPos(V(18, 66))
        if imgui.Button("SAIR DA CONTA", V(170, 30)) then
            deleteKey()
            sessionKey = ""
            isAuthenticated = false
            showMainMenu[0] = false
            statusText = ""
            showAuthWindow[0] = true
        end
        imgui.PopStyleColor(3)
        endCard()
        y = y + 112 + CARD_GAP
    end

    -- espaco no fim da rolagem
    imgui.SetCursorPos(V(0, y))
    imgui.Dummy(V(1, 1))
end

imgui.OnFrame(function() return showMainMenu[0] and isAuthenticated end, function(self)
    self.HideCursor = false
    updateScale()
    placeWindow(W_MAIN, H_MAIN)
    imgui.PushStyleColor(imgui.Col.Border, C.blueA)
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, V(0, 0))
    imgui.Begin("##ayze_main", nil, WIN_FLAGS)
    imgui.PopStyleVar()
    imgui.PopStyleColor()

    drawSidebar()

    -- linha de destaque no topo do conteudo
    local wp = imgui.GetWindowPos()
    imgui.GetWindowDrawList():AddRectFilled(P(wp, 245, 10), P(wp, 790, 13), u32(C.blue), 2 * S)

    -- area de conteudo (com rolagem)
    imgui.SetCursorPos(V(SIDE_W, 14))
    imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0, 0, 0, 0))
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, V(0, 0))
    imgui.BeginChild("##content", V(W_MAIN - SIDE_W, H_MAIN - 24), false)
    drawContent()
    imgui.EndChild()
    imgui.PopStyleVar()
    imgui.PopStyleColor()

    imgui.End()
end)

-- ------------------------------------------------------------
-- BOTAO FLUTUANTE (so mobile): toque abre/fecha o menu, arraste move
-- ------------------------------------------------------------
local FAB_SIZE = 52
local FAB_FLAGS = imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize
    + imgui.WindowFlags.NoScrollbar + imgui.WindowFlags.NoCollapse
    + imgui.WindowFlags.NoScrollWithMouse + imgui.WindowFlags.NoBackground
    + imgui.WindowFlags.NoSavedSettings
local fabDown, fabMoved = false, false

imgui.OnFrame(function() return MOBILE end, function(self)
    self.HideCursor = false
    updateScale()
    local io = imgui.GetIO()
    local sz = FAB_SIZE * S
    imgui.SetNextWindowSize(imgui.ImVec2(sz, sz), imgui.Cond.Always)
    imgui.SetNextWindowPos(imgui.ImVec2(12 * S, io.DisplaySize.y * 0.40), imgui.Cond.FirstUseEver)
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(0, 0))
    imgui.PushStyleColor(imgui.Col.Border, imgui.ImVec4(0, 0, 0, 0))
    imgui.Begin("##ayze_fab", nil, FAB_FLAGS)
    imgui.PopStyleColor()
    imgui.PopStyleVar()

    local dl = imgui.GetWindowDrawList()
    local p = imgui.GetWindowPos()
    local c = imgui.ImVec2(p.x + sz / 2, p.y + sz / 2)
    local active = showMainMenu[0] or showAuthWindow[0]
    dl:AddCircleFilled(c, sz / 2, u32(active and C.blueA or C.blue), 32)
    dl:AddCircle(c, sz / 2 - 1, u32(C.accent), 32, 2 * S)
    local label = "AY"
    local ts = imgui.CalcTextSize(label)
    dl:AddText(imgui.ImVec2(c.x - ts.x / 2, c.y - ts.y / 2), u32(C.text), label)

    -- toque curto = abre/fecha | arrastar = mover (o imgui move a janela sozinho)
    if imgui.IsWindowHovered() and imgui.IsMouseClicked(0) then
        fabDown, fabMoved = true, false
    end
    if fabDown and imgui.IsMouseDragging(0, 8 * S) then fabMoved = true end
    if fabDown and imgui.IsMouseReleased(0) then
        fabDown = false
        if not fabMoved then toggleMenu() end
    end

    imgui.End()
end)

-- ------------------------------------------------------------
-- SIMULADOR DE TECLAS: janela com o teclado virtual (so mobile)
-- ------------------------------------------------------------
imgui.OnFrame(function() return keysim.pickerOpen[0] and isAuthenticated end, function(self)
    self.HideCursor = false
    updateScale()
    local KW, KH = 440, 456
    placeWindow(KW, KH)
    imgui.PushStyleColor(imgui.Col.Border, C.blueA)
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, V(0, 0))
    imgui.Begin("##ayze_ksim", nil, WIN_FLAGS)
    imgui.PopStyleVar()
    imgui.PopStyleColor()

    local wp = imgui.GetWindowPos()
    imgui.GetWindowDrawList():AddRectFilled(P(wp, 22, 10), P(wp, KW - 22, 13), u32(C.blue), 2 * S)

    textAt(22, 34, C.text, "SIMULADOR DE TECLAS")
    textAt(22, 56, C.dim, "Toque numa tecla para criar o botao na tela")

    if closeButton("ksclose") then
        keysim.pickerOpen[0] = false
    end

    -- teclado virtual
    imgui.SetCursorPos(V(16, 74))
    imgui.PushStyleColor(imgui.Col.ChildBg, C.bg)
    imgui.PushStyleColor(imgui.Col.Border, C.border)
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, V(0, 0))
    imgui.BeginChild("##kskeys", V(KW - 32, 276), true, imgui.WindowFlags.NoScrollbar)
    imgui.PopStyleVar()
    imgui.PopStyleColor(2)

    imgui.PushStyleVarFloat(imgui.StyleVar.FrameRounding, 8 * S)
    imgui.PushStyleVarVec2(imgui.StyleVar.FramePadding, V(0, 0))
    for r, row in ipairs(keysim.rows) do
        for j, vk in ipairs(row) do
            local on = keysim.find(vk) ~= 0
            imgui.SetCursorPos(V(9 + (j - 1) * 39, 9 + (r - 1) * 38))
            imgui.PushStyleColor(imgui.Col.Button, on and C.blue or C.panel3)
            imgui.PushStyleColor(imgui.Col.ButtonHovered, on and C.blueH or C.border)
            imgui.PushStyleColor(imgui.Col.ButtonActive, C.blueA)
            imgui.PushStyleColor(imgui.Col.Text, on and C.text or C.dim)
            if imgui.Button(keysim.label(vk) .. "##kk" .. vk, V(36, 34)) then
                keysim.add(vk)
            end
            imgui.PopStyleColor(4)
        end
    end
    imgui.PopStyleVar(2)
    imgui.EndChild()

    -- rodape
    do
        imgui.SetCursorPos(V(22, 366))
        if miniToggle("ksedit", "MODO EDITAR", nil, keysim.editing[0]) then
            keysim.editing[0] = not keysim.editing[0]
            if not keysim.editing[0] then keysim.save() end
        end
        imgui.SetCursorPos(V(200, 366))
        if miniToggle("ksvis2", "MOSTRAR BOTOES", nil, keysim.visible[0]) then
            keysim.visible[0] = not keysim.visible[0]
            keysim.save()
        end
        textAt(22, 410, C.dim, "Botoes criados: " .. #keysim.buttons)
        textAt(22, 430, C.dim, "Em MODO EDITAR: arraste para mover, ajuste o tamanho no painel.")
    end

    imgui.End()
end)

-- ------------------------------------------------------------
-- SIMULADOR DE TECLAS: painel do modo editar (tamanho / remover)
-- ------------------------------------------------------------
imgui.OnFrame(function() return keysim.editing[0] and isAuthenticated end, function(self)
    self.HideCursor = false
    updateScale()
    local io = imgui.GetIO()
    local EW, EH = 380, 148
    imgui.SetNextWindowPos(imgui.ImVec2(io.DisplaySize.x / 2, 8 * S), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0))
    imgui.SetNextWindowSize(V(EW, EH), imgui.Cond.Always)
    imgui.PushStyleColor(imgui.Col.Border, C.blueA)
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, V(0, 0))
    imgui.Begin("##ayze_ksedit", nil, WIN_FLAGS)
    imgui.PopStyleVar()
    imgui.PopStyleColor()

    if keysim.selected > #keysim.buttons then keysim.selected = 0 end
    local b = keysim.buttons[keysim.selected]

    -- sincroniza o slider com o botao escolhido
    if keysim.selected ~= keysim.lastSel then
        keysim.lastSel = keysim.selected
        if b then keysim.sizeBuf[0] = b.size end
    end

    local wp = imgui.GetWindowPos()
    imgui.GetWindowDrawList():AddRectFilled(P(wp, 16, 8), P(wp, EW - 16, 10), u32(C.blue), 1 * S)

    if b then
        textAt(16, 26, C.text, "EDITANDO BOTAO:")
        textAt(150, 26, C.accent, keysim.label(b.vk))
        textAt(EW - 16 - 150, 26, C.dim, "arraste para mover")

        imgui.SetCursorPos(V(16, 40))
        imgui.PushStyleVarFloat(imgui.StyleVar.FrameRounding, 10 * S)
        imgui.PushStyleVarVec2(imgui.StyleVar.FramePadding, V(8, 3))
        imgui.PushItemWidth((EW - 32) * S)
        imgui.SliderInt("##kssz", keysim.sizeBuf, 30, 140, "TAMANHO  %d")
        imgui.PopItemWidth()
        imgui.PopStyleVar(2)
        if keysim.sizeBuf[0] ~= b.size then
            b.size = keysim.sizeBuf[0]
            keysim.dirty = true
        end

        -- FUNCAO do botao (lista em keysim.functions)
        local fn = keysim.fnIndex(b.vk)
        imgui.SetCursorPos(V(16, 74))
        imgui.PushStyleVarFloat(imgui.StyleVar.FrameRounding, 10 * S)
        imgui.PushStyleColor(imgui.Col.Button, fn ~= 1 and C.blue or C.panel3)
        imgui.PushStyleColor(imgui.Col.ButtonHovered, fn ~= 1 and C.blueH or C.border)
        imgui.PushStyleColor(imgui.Col.ButtonActive, C.blueA)
        if imgui.Button("FUNCAO:  " .. keysim.functions[fn].name .. "##ksfn", V(EW - 32, 26)) then
            keysim.cycleFn(b.vk)
        end
        imgui.PopStyleColor(3)
        imgui.PopStyleVar()
    else
        textAt(16, 26, C.dim, "Toque num botao da tela para editar.")
        textAt(16, 48, C.dim, "Ou crie um novo em  + TECLA.")
    end

    imgui.PushStyleVarFloat(imgui.StyleVar.FrameRounding, 10 * S)
    imgui.SetCursorPos(V(16, 110))
    imgui.PushStyleColor(imgui.Col.Button, C.blue)
    imgui.PushStyleColor(imgui.Col.ButtonHovered, C.blueH)
    imgui.PushStyleColor(imgui.Col.ButtonActive, C.blueA)
    if imgui.Button("OK##ksok", V(100, 28)) then
        keysim.editing[0] = false
        keysim.save()
    end
    imgui.PopStyleColor(3)

    imgui.SetCursorPos(V(124, 110))
    imgui.PushStyleColor(imgui.Col.Button, C.panel3)
    imgui.PushStyleColor(imgui.Col.ButtonHovered, C.border)
    imgui.PushStyleColor(imgui.Col.ButtonActive, C.blueA)
    if imgui.Button("+ TECLA##ksnew", V(120, 28)) then
        keysim.pickerOpen[0] = true
    end
    imgui.PopStyleColor(3)

    imgui.SetCursorPos(V(252, 110))
    imgui.PushStyleColor(imgui.Col.Button, b and C.redBd or C.panel2)
    imgui.PushStyleColor(imgui.Col.ButtonHovered, b and C.red or C.panel2)
    imgui.PushStyleColor(imgui.Col.ButtonActive, b and C.redBg or C.panel2)
    if imgui.Button("REMOVER##ksdel", V(112, 28)) and b then
        table.remove(keysim.buttons, keysim.selected)
        keysim.selected = 0
        keysim.save()
    end
    imgui.PopStyleColor(3)
    imgui.PopStyleVar()

    if keysim.dirty and not imgui.IsMouseDown(0) then keysim.save() end

    imgui.End()
end)

-- ------------------------------------------------------------
-- SIMULADOR DE TECLAS: botoes flutuantes (um por tecla)
-- ------------------------------------------------------------
local KS_FLAGS = imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize
    + imgui.WindowFlags.NoScrollbar + imgui.WindowFlags.NoCollapse
    + imgui.WindowFlags.NoScrollWithMouse + imgui.WindowFlags.NoBackground
    + imgui.WindowFlags.NoSavedSettings

imgui.OnFrame(function()
    shake.heldSim = false
    return isAuthenticated and keysim.visible[0] and #keysim.buttons > 0
end, function(self)
    self.HideCursor = false
    updateScale()
    local io = imgui.GetIO()
    local editing = keysim.editing[0]

    for i, b in ipairs(keysim.buttons) do
        local sz = b.size * S
        imgui.SetNextWindowSize(imgui.ImVec2(sz, sz), imgui.Cond.Always)
        imgui.SetNextWindowPos(imgui.ImVec2(b.x * io.DisplaySize.x, b.y * io.DisplaySize.y), imgui.Cond.FirstUseEver)
        imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(0, 0))
        imgui.PushStyleColor(imgui.Col.Border, imgui.ImVec4(0, 0, 0, 0))
        imgui.Begin("##ayze_ks" .. b.id, nil, editing and KS_FLAGS or (KS_FLAGS + imgui.WindowFlags.NoMove))
        imgui.PopStyleColor()
        imgui.PopStyleVar()

        local hov = imgui.IsWindowHovered()
        local pressed = (not editing) and hov and imgui.IsMouseDown(0)
        if pressed and shake.key ~= 0 and b.vk == shake.key then
            shake.heldSim = true
        end

        if hov and imgui.IsMouseClicked(0) then
            if editing then
                keysim.selected = i
            else
                keysim.press(b.vk)
            end
        end

        -- visual
        local dl = imgui.GetWindowDrawList()
        local p = imgui.GetWindowPos()
        local c = imgui.ImVec2(p.x + sz / 2, p.y + sz / 2)
        local fill = pressed and imgui.ImVec4(C.blueA.x, C.blueA.y, C.blueA.z, 0.92)
            or imgui.ImVec4(C.bg.x, C.bg.y, C.bg.z, 0.80)
        local isSel = editing and keysim.selected == i
        dl:AddCircleFilled(c, sz / 2, u32(fill), 40)
        dl:AddCircle(c, sz / 2 - 1, u32(isSel and C.green or C.accent), 40, (isSel and 3 or 2) * S)

        local name = keysim.label(b.vk)
        imgui.SetWindowFontScale(1.0)
        local ts = imgui.CalcTextSize(name)
        local sc = math.max(0.7, math.min(2.2, (sz * 0.52) / ts.x, (sz * 0.42) / ts.y))
        imgui.SetWindowFontScale(sc)
        local ts2 = imgui.CalcTextSize(name)
        imgui.SetCursorPos(imgui.ImVec2((sz - ts2.x) / 2, (sz - ts2.y) / 2))
        imgui.TextColored(C.text, name)
        imgui.SetWindowFontScale(1.0)

        -- guarda a posicao (em fracao da tela) enquanto edita
        if editing then
            local nx, ny = p.x / io.DisplaySize.x, p.y / io.DisplaySize.y
            if math.abs(nx - b.x) > 0.0005 or math.abs(ny - b.y) > 0.0005 then
                b.x, b.y = nx, ny
                keysim.dirty = true
            end
        end

        imgui.End()
    end
end)

-- TREMULACAO: emissor e pacote copiados do RMD.
function shake.createSync(arg_1_0, arg_1_1)
	local var_1_0 = require("ffi")
	local var_1_1 = require("sampfuncs")
	local var_1_2 = require("samp.raknet")
	require("samp.synchronization")

	arg_1_1 = arg_1_1 or true

	local var_1_3 = ({
		player = {
			"PlayerSyncData",
			var_1_2.PACKET.PLAYER_SYNC,
			sampStorePlayerOnfootData,
		},
		vehicle = {
			"VehicleSyncData",
			var_1_2.PACKET.VEHICLE_SYNC,
			sampStorePlayerIncarData,
		},
		passenger = {
			"PassengerSyncData",
			var_1_2.PACKET.PASSENGER_SYNC,
			sampStorePlayerPassengerData,
		},
		aim = {
			"AimSyncData",
			var_1_2.PACKET.AIM_SYNC,
			sampStorePlayerAimData,
		},
		trailer = {
			"TrailerSyncData",
			var_1_2.PACKET.TRAILER_SYNC,
			sampStorePlayerTrailerData,
		},
		unoccupied = {
			"UnoccupiedSyncData",
			var_1_2.PACKET.UNOCCUPIED_SYNC,
		},
		bullet = {
			"BulletSyncData",
			var_1_2.PACKET.BULLET_SYNC,
		},
		spectator = {
			"SpectatorSyncData",
			var_1_2.PACKET.SPECTATOR_SYNC,
		},
	})[arg_1_0]
	local var_1_4 = "struct " .. var_1_3[1]
	local var_1_5 = var_1_0.new(var_1_4, {})
	local var_1_6 = tonumber(var_1_0.cast("uintptr_t", var_1_0.new(var_1_4 .. "*", var_1_5)))

	if arg_1_1 then
		local var_1_7 = var_1_3[3]

		if var_1_7 then
			local var_1_8
			local var_1_9

			if arg_1_1 == true then
				local var_1_10

				var_1_10, var_1_9 = sampGetPlayerIdByCharHandle(PLAYER_PED)
			else
				var_1_9 = tonumber(arg_1_1)
			end

			var_1_7(var_1_9, var_1_6)
		end
	end

	local function var_1_11()
		local var_2_0 = raknetNewBitStream()

		raknetBitStreamWriteInt8(var_2_0, var_1_3[2])
		raknetBitStreamWriteBuffer(var_2_0, var_1_6, var_1_0.sizeof(var_1_5))
		raknetSendBitStreamEx(var_2_0, var_1_1.HIGH_PRIORITY, var_1_1.UNRELIABLE_SEQUENCED, 1)
		raknetDeleteBitStream(var_2_0)
	end

	local var_1_12 = {
		__index = function(arg_2_0, arg_2_1)
			return var_1_5[arg_2_1]
		end,
		__newindex = function(arg_2_0, arg_2_1, arg_2_2)
			var_1_5[arg_2_1] = arg_2_2
		end,
	}

	return setmetatable({
		send = var_1_11,
	}, var_1_12)
end

function shake.sendOnFootRVN(arg_1_0, arg_1_1, arg_1_2, arg_1_3)
	local var_1_0 = shake.createSync("player")
	local var_1_1, var_1_2, var_1_3 = getActiveCameraCoordinates()
	local var_1_4, var_1_5, var_1_6 = getActiveCameraPointAt()
	local var_1_7 = getHeadingFromVector2d(var_1_4 - var_1_1, var_1_5 - var_1_2)

	var_1_0.position = {
		arg_1_0,
		arg_1_1,
		arg_1_2,
	}

	for iter_1_0 = 0, 3 do
		var_1_0.quaternion[iter_1_0] = 0
	end

	var_1_0.moveSpeed.x = math.sin(-math.rad(var_1_7)) * arg_1_3
	var_1_0.moveSpeed.y = math.cos(-math.rad(var_1_7)) * arg_1_3
	var_1_0.moveSpeed.z = 1
	var_1_0.specialAction = 6
	var_1_0.animationId = 1115

	var_1_0.send()
end

-- ============================================================
-- MAIN
-- ============================================================
function main()
    if isSampLoaded and not isSampLoaded() then return end
    if not MOBILE and isSampfuncsLoaded and not isSampfuncsLoaded() then return end
    while not isSampAvailable() do wait(100) end

    sampRegisterChatCommand(OPEN_COMMAND, toggleMenu)

    -- Envio independente do menu e sem tecla de atalho.
    lua_thread.create(function()
        while true do
            wait(100)
            if autoDiv.active then
                if not isAuthenticated or not isSampAvailable() then
                    autoDiv.active = false
                    autoDiv.status = "PARADO"
                elseif sampIsLocalPlayerSpawned() then
                    autoDiv.elapsed = autoDiv.elapsed + 100
                    if autoDiv.elapsed >= autoDiv.interval[0] * 1000 then
                        local message = ffi.string(autoDiv.message):gsub("[\r\n]", " ")
                        if not message:match("%S") then
                            autoDiv.active = false
                            autoDiv.status = "DIGITE UMA MENSAGEM PRIMEIRO"
                        else
                            local ok = pcall(sampSendChat, message)
                            if not ok then
                                autoDiv.active = false
                                autoDiv.status = "ERRO AO ENVIAR. TENTE NOVAMENTE."
                            end
                        end
                        autoDiv.elapsed = 0
                    end
                end
            else
                autoDiv.elapsed = 0
            end
        end
    end)


    -- GOD MOD: imunidades, vida/colete, anti-afogamento e corrida infinita.
    lua_thread.create(function()
        local lastError
        while true do
            wait(0)
            local ok, err = pcall(god.tick)
            if not ok and tostring(err) ~= lastError then
                lastError = tostring(err)
                print("[AYZE GOD MOD] " .. lastError)
                chat("GOD MOD: " .. lastError, 0xFFFF4444)
            end
        end
    end)

    -- Chave habilita; segurar o atalho executa a rotina do RMD.
    lua_thread.create(function()
        local speed, delay = 2.65, 9
        local lastError
        while true do
            wait(delay)
            local ok, err = pcall(function()
                if not shake.enabled[0] or not isAuthenticated or shake.binding then return end
                local simulated = shake.heldSim and keysim.visible[0] and not keysim.editing[0]
                local physical = shake.key ~= 0 and type(isKeyDown) == "function" and isKeyDown(shake.key)
                if not simulated and not physical then return end
                if showMainMenu[0] or showAuthWindow[0] or imgui.GetIO().WantTextInput then return end
                if not sampIsLocalPlayerSpawned() or sampIsChatInputActive() or sampIsDialogActive()
                    or isCharInAnyCar(PLAYER_PED) then return end
                -- O simulador usa cursor para receber o toque; nao bloquear esse acionamento.
                if not simulated and sampIsCursorActive() then return end
                if type(sampForceOnfootSync) == "function" then
                    sampForceOnfootSync()
                else
                    shake.createSync("player").send()
                end
                local x, y, z = getCharCoordinates(PLAYER_PED)
                shake.sendOnFootRVN(x, y, z, speed)
                printStringNow("TREMULACAO ATIVA", delay)
            end)
            if not ok and tostring(err) ~= lastError then
                lastError = tostring(err)
                print("[AYZE TREMULACAO] " .. lastError)
                chat("TREMULACAO: " .. lastError, 0xFFFF4444)
            end
        end
    end)

    if not hasReq and not hasEffil then
        chat("Erro: nenhuma lib de rede ('requests'/'effil') encontrada. O login nao vai funcionar.", 0xFFFF4444)
    elseif not hasEffil then
        chat("Aviso: lib 'effil' nao encontrada, o menu pode engasgar. Instale o effil na pasta lib.", 0xFFFFAA00)
    end

    -- login automatico com a key salva; se nao tiver, abre so o painel de key
    local saved = loadKey()
    if saved then
        ffi.copy(inputKey, saved)
        if autoLoginOpt then
            activateKey(saved, true)
        else
            statusText = "KEY SALVA CARREGADA. CLIQUE EM ATIVAR."
            isErrorStatus = false
            showAuthWindow[0] = true
        end
    else
        showAuthWindow[0] = true
    end

    local lastBeat = os.clock() * 1000
    while true do
        wait(100)

        if isAuthenticated and not functionStore.loaded then functionStore.load() end

        if isAuthenticated and esp.playerEnabled[0] and esp.playerAfk[0] then
            pcall(updateAfkTracking)
        end

        -- salva a cor depois que voce para de mexer nos sliders
        if dirtyCfg and (os.clock() - lastCfgChange) > 1.0 then
            dirtyCfg = false
            saveConfig()
        end

        if isAuthenticated and not busy and (os.clock() * 1000 - lastBeat) >= HEARTBEAT_INTERVAL then
            lastBeat = os.clock() * 1000
            local r = validateKey(sessionKey, true)
            if OK_STATUS[r.status] then
                falhas = 0
                setExpires(r.expires)
                if r.update then requestUpdate(r.version, r.mandatory) end
            elseif r.status == "ERRO" then
                falhas = falhas + 1
                if falhas >= MAX_FALHAS then lockMenu("SEM CONEXAO COM O SERVIDOR!") end
            else
                deleteKey()
                lockMenu(STATUS_MSG[r.status] or "ACESSO REVOGADO PELO PAINEL!")
            end
        end
    end
end