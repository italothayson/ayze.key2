local imgui = require 'mimgui'
local ffi = require 'ffi'
local requests = require 'requests'

-- >>> IMPORTANTE: esta constante TEM que ser igual ao numero publicado no painel (ex: "1.0.0")
local SCRIPT_VERSION = "1.0.0"
local API_BASE = "https://c22ayze.discloud.app" -- URL do painel AYZE (sem barra no final)

local showAuthWindow = imgui.new.bool(false)
local showMainMenu = imgui.new.bool(false)
local isAuthenticated = false
local selectedTab = 1
local fakeBool = imgui.new.bool(false) -- (corrigido: antes era recriado a cada frame)

local inputKey = imgui.new.char[256]("")
local statusText = ""
local isErrorStatus = true
local userKeyStr = ""
local expiresText = "..."
local sessionKey = ""

-- HWID: serial do volume C: + nome do PC (o servidor vincula a key ao primeiro HWID usado)
ffi.cdef[[ int GetVolumeInformationA(const char*, char*, unsigned long, unsigned long*, unsigned long*, unsigned long*, char*, unsigned long); ]]
local function getHWID()
    local serial = ffi.new("unsigned long[1]")
    ffi.C.GetVolumeInformationA("C:\\", nil, 0, serial, nil, nil, nil, 0)
    local pc = (os.getenv("COMPUTERNAME") or "PC"):gsub("[^%w_-]", "")
    return string.format("%08X-%s-%s", tonumber(serial[0]), pc, (os.getenv("PROCESSOR_IDENTIFIER") or "CPU"):gsub("[^%w]", ""):sub(1, 16))
end
local HWID = getHWID()

local function urlenc(s) return (tostring(s):gsub("[^%w_%-%.]", function(c) return string.format("%%%02X", c:byte()) end)) end

local function apiPost(path, key, extra)
    local body = "key=" .. urlenc(key) .. "&hwid=" .. urlenc(HWID) .. "&version=" .. urlenc(SCRIPT_VERSION) .. (extra or "")
    return requests.post(API_BASE .. path, {
        data = body,
        headers = { ["Content-Type"] = "application/x-www-form-urlencoded" }
    })
end

-- Consulta /api/validate e devolve uma tabela simples
local function validateKey(key, heartbeat)
    local ok, resp = pcall(apiPost, "/api/validate", key, heartbeat and "&hb=1" or "")
    if not ok or not resp or not resp.text or resp.status_code ~= 200 then return { status = "ERRO" } end
    local t = resp.text
    return {
        status = t:match('"status"%s*:%s*"([%w_]+)"') or "ERRO",
        expires = tonumber(t:match('"expires"%s*:%s*(%d+)')) or 0,
        update = t:find('"update"%s*:%s*true') ~= nil,
        mandatory = t:find('"mandatory"%s*:%s*true') ~= nil,
        version = t:match('"version"%s*:%s*"([%d%.]*)"') or "",
    }
end

-- Baixa a versao nova do painel e recarrega o script
local function downloadUpdate(key)
    local ok, resp = pcall(apiPost, "/api/update/download", key)
    if not ok or not resp or resp.status_code ~= 200 or #resp.text < 200 or not resp.text:find("SCRIPT_VERSION", 1, true) then
        return false
    end
    local path = thisScript().path
    local f = io.open(path, "wb")
    if not f then return false end
    f:write(resp.text); f:close()
    return true
end

local STATUS_MSG = {
    INVALIDA = "CHAVE INVALIDA OU INEXISTENTE!",
    EXPIRADA = "CHAVE EXPIRADA! ADQUIRA UMA NOVA.",
    CANCELADA = "CHAVE BANIDA / CANCELADA PELO ADMIN!",
    BANIDO = "DISPOSITIVO BANIDO!",
    HWID_INVALIDO = "CHAVE JA VINCULADA A OUTRO PC!",
}

local function lockMenu(msg)
    isAuthenticated = false
    showMainMenu[0] = false
    statusText = msg or ""
    isErrorStatus = true
    showAuthWindow[0] = true
end

imgui.OnInitialize(function()
    local style = imgui.GetStyle()
    local colors = style.Colors

    -- Paleta Original Ayze para a Auth
    colors[imgui.Col.WindowBg] = imgui.ImVec4(0.04, 0.07, 0.12, 1.00)
    colors[imgui.Col.TitleBg] = imgui.ImVec4(0.24, 0.00, 0.55, 1.00)
    colors[imgui.Col.TitleBgActive] = imgui.ImVec4(0.24, 0.00, 0.55, 1.00)
    colors[imgui.Col.Button] = imgui.ImVec4(0.24, 0.00, 0.55, 1.00) 
    colors[imgui.Col.ButtonHovered] = imgui.ImVec4(0.32, 0.05, 0.65, 1.00)
    colors[imgui.Col.ButtonActive] = imgui.ImVec4(0.18, 0.00, 0.45, 1.00)
    colors[imgui.Col.FrameBg] = imgui.ImVec4(0.15, 0.15, 0.15, 1.00) 
    colors[imgui.Col.FrameBgHovered] = imgui.ImVec4(0.20, 0.20, 0.20, 1.00)
    colors[imgui.Col.FrameBgActive] = imgui.ImVec4(0.25, 0.25, 0.25, 1.00)
    colors[imgui.Col.Border] = imgui.ImVec4(0.24, 0.00, 0.55, 0.30)

    style.FramePadding = imgui.ImVec2(8.0, 10.0)
    style.WindowRounding = 8.0
    style.FrameRounding = 8.0 
    style.ChildRounding = 8.0
    style.WindowBorderSize = 1.0
    style.FrameBorderSize = 0.0 
end)

-- JANELA DE AUTENTICAÇÃO
local renderAuthWindow = imgui.OnFrame(
    function() return showAuthWindow[0] end,
    function(player)
        imgui.SetNextWindowSize(imgui.ImVec2(500, 360), imgui.Cond.FirstUseEver)
        local windowFlags = bit.bor(imgui.WindowFlags.NoCollapse, imgui.WindowFlags.NoResize, imgui.WindowFlags.NoTitleBar)
        
        if imgui.Begin("Ayze Auth", showAuthWindow, windowFlags) then
            local windowWidth = imgui.GetWindowWidth()
            local inputWidth = 380
            local startX = (windowWidth - inputWidth) / 2

            imgui.Spacing()
            imgui.Spacing()
            
            imgui.SetWindowFontScale(2.0) 
            imgui.SetCursorPosX((windowWidth - imgui.CalcTextSize("AYZE").x) / 2)
            imgui.TextColored(imgui.ImVec4(1.0, 1.0, 1.0, 1.0), "AYZE")
            imgui.SetWindowFontScale(1.0)
            
            imgui.SetWindowFontScale(1.05)
            imgui.SetCursorPosX((windowWidth - imgui.CalcTextSize("AUTENTICAÇÃO DE LICENÇA").x) / 2)
            imgui.TextColored(imgui.ImVec4(0.40, 0.40, 0.90, 1.00), "AUTENTICAÇÃO DE LICENÇA")
            imgui.SetWindowFontScale(1.0)
            
            imgui.Spacing()
            
            imgui.SetCursorPosX(startX)
            imgui.TextColored(imgui.ImVec4(0.24, 0.00, 0.55, 0.4), "--------------------------------------------------------------------------------")
            
            imgui.Spacing()
            
            if statusText ~= "" then
                local txtCol = isErrorStatus and imgui.ImVec4(1.0, 0.25, 0.25, 1.0) or imgui.ImVec4(0.25, 1.0, 0.25, 1.0)
                imgui.SetCursorPosX((windowWidth - imgui.CalcTextSize(statusText).x) / 2)
                imgui.TextColored(txtCol, statusText)
                imgui.Spacing()
            else
                imgui.Dummy(imgui.ImVec2(100, 18)) 
            end

            imgui.SetCursorPosX(startX)
            imgui.TextColored(imgui.ImVec4(0.7, 0.7, 0.7, 1.0), "SUA CHAVE DE ACESSO:")
            
            imgui.SetCursorPosX(startX)
            imgui.PushItemWidth(inputWidth)
            imgui.InputText("##keyinput", inputKey, ffi.sizeof(inputKey))
            imgui.PopItemWidth()

            imgui.Spacing()
            imgui.Spacing()

            imgui.SetCursorPosX(startX)
            
            if imgui.Button("ATIVAR CHAVE", imgui.ImVec2(inputWidth, 44)) then
                local typedKey = ffi.string(inputKey)
                if typedKey == "" then
                    statusText = "POR FAVOR, INSIRA UMA CHAVE!"
                    isErrorStatus = true
                else
                    statusText = "VERIFICANDO NO SERVIDOR..."
                    isErrorStatus = false
                    
                    lua_thread.create(function()
                        local r = validateKey(typedKey, false)
                        if r.status == "VALIDA" then
                            if r.update then
                                statusText = "ATUALIZANDO MENU PARA v" .. r.version .. "..."
                                if downloadUpdate(typedKey) then
                                    statusText = "ATUALIZADO! RECARREGANDO..."
                                    wait(1000)
                                    thisScript():reload()
                                    return
                                elseif r.mandatory then
                                    statusText = "FALHA NA ATUALIZACAO OBRIGATORIA!"
                                    isErrorStatus = true
                                    return
                                end
                            end
                            statusText = "CHAVE AUTORIZADA! A ENTRAR..."
                            isErrorStatus = false
                            userKeyStr = typedKey
                            sessionKey = typedKey
                            expiresText = r.expires == 0 and "Vitalicio" or os.date("%d/%m/%Y %H:%M", r.expires)
                            wait(1000)
                            isAuthenticated = true
                            showAuthWindow[0] = false
                            showMainMenu[0] = true
                            statusText = ""
                        elseif r.status == "ERRO" then
                            statusText = "ERRO AO CONECTAR COM O SERVIDOR!"
                            isErrorStatus = true
                        else
                            statusText = STATUS_MSG[r.status] or "CHAVE INVALIDA!"
                            isErrorStatus = true
                        end
                    end)
                end
            end

            imgui.Spacing()
            imgui.Spacing()
            
            local versionText = "Versão do menu 1.0.0 • Ayze"
            imgui.SetCursorPosX((windowWidth - imgui.CalcTextSize(versionText).x) / 2)
            imgui.TextColored(imgui.ImVec4(0.3, 0.3, 0.4, 0.8), versionText)

            imgui.End()
        end
    end
)

-- JANELA DO MENU PRINCIPAL (Design Baseado na Imagem)
local renderMainWindow = imgui.OnFrame(
    function() return showMainMenu[0] end,
    function(player)
        imgui.SetNextWindowSize(imgui.ImVec2(800, 500), imgui.Cond.FirstUseEver)
        local windowFlags = bit.bor(imgui.WindowFlags.NoCollapse, imgui.WindowFlags.NoResize, imgui.WindowFlags.NoTitleBar)
        
        -- Remove o espaçamento padrão da janela para os painéis colarem aos cantos
        imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(0, 0))
        
        if imgui.Begin("Ayze Main Menu", showMainMenu, windowFlags) then
            
            -- CORES DOS PAINÉIS
            local colorLeftBar = imgui.ImVec4(0.12, 0.12, 0.13, 1.00)
            local colorMidBar = imgui.ImVec4(0.15, 0.15, 0.16, 1.00)
            local colorMainBg = imgui.ImVec4(0.08, 0.08, 0.09, 1.00)
            local colorPurple = imgui.ImVec4(0.40, 0.20, 0.80, 1.00)
            
            ---------------------------------------------------------
            -- 1. BARRA LATERAL ESQUERDA (ÍCONES)
            ---------------------------------------------------------
            imgui.PushStyleColor(imgui.Col.ChildBg, colorLeftBar)
            if imgui.BeginChild("LeftBar", imgui.ImVec2(50, 0), false) then
                imgui.Spacing()
                imgui.Spacing()
                
                -- Substitui estas letras/símbolos por FontAwesome se tiveres a biblioteca incluída
                imgui.SetCursorPosX(15)
                imgui.TextColored(colorPurple, "O") -- Ícone caveira roxa topo
                
                imgui.Spacing(); imgui.Spacing(); imgui.Spacing()
                
                imgui.SetCursorPosX(15)
                imgui.TextColored(selectedTab == 1 and imgui.ImVec4(1,1,1,1) or imgui.ImVec4(0.5,0.5,0.5,1), "O") -- Aba 1
                
                imgui.Spacing(); imgui.Spacing()
                
                imgui.SetCursorPosX(15)
                imgui.TextColored(selectedTab == 2 and imgui.ImVec4(1,1,1,1) or imgui.ImVec4(0.5,0.5,0.5,1), "T") -- Aba 2
                
                imgui.Spacing(); imgui.Spacing()
                
                imgui.SetCursorPosX(15)
                imgui.TextColored(selectedTab == 3 and imgui.ImVec4(1,1,1,1) or imgui.ImVec4(0.5,0.5,0.5,1), "E") -- Aba 3
                
                imgui.Spacing(); imgui.Spacing()
                
                imgui.SetCursorPosX(15)
                imgui.TextColored(selectedTab == 4 and imgui.ImVec4(1,1,1,1) or imgui.ImVec4(0.5,0.5,0.5,1), "*") -- Aba 4 Configs
                
                imgui.EndChild()
            end
            imgui.PopStyleColor()

            imgui.SameLine(0, 0)

            ---------------------------------------------------------
            -- 2. BARRA DO MEIO (TÍTULO E INFO DO UTILIZADOR)
            ---------------------------------------------------------
            imgui.PushStyleColor(imgui.Col.ChildBg, colorMidBar)
            if imgui.BeginChild("MidBar", imgui.ImVec2(220, 0), false) then
                imgui.Spacing()
                imgui.Spacing()
                
                -- Título
                imgui.SetCursorPosX(15)
                imgui.SetWindowFontScale(1.2)
                imgui.TextColored(colorPurple, "O") 
                imgui.SameLine()
                imgui.TextColored(imgui.ImVec4(1, 1, 1, 1), "AYZE MENU")
                imgui.SetWindowFontScale(1.0)
                
                imgui.Spacing()
                -- Aqui podes adicionar submenus ou opções da aba selecionada
                
                -- Painel de Informação do Utilizador no fundo
                imgui.SetCursorPosY(imgui.GetWindowHeight() - 65)
                imgui.SetCursorPosX(10)
                
                imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0.18, 0.18, 0.20, 1.00))
                if imgui.BeginChild("UserInfoBox", imgui.ImVec2(200, 55), true) then
                    imgui.TextColored(imgui.ImVec4(0.8, 0.8, 0.8, 1), "Usuario:")
                    imgui.SameLine()
                    imgui.TextColored(imgui.ImVec4(1, 1, 1, 1), userKeyStr)
                    
                    imgui.TextColored(imgui.ImVec4(0.8, 0.8, 0.8, 1), "expira:")
                    imgui.SameLine()
                    imgui.TextColored(colorPurple, expiresText)
                    imgui.EndChild()
                end
                imgui.PopStyleColor()

                imgui.EndChild()
            end
            imgui.PopStyleColor()

            imgui.SameLine(0, 0)

            ---------------------------------------------------------
            -- 3. PAINEL PRINCIPAL (CONTEÚDO DO MOD)
            ---------------------------------------------------------
            imgui.PushStyleColor(imgui.Col.ChildBg, colorMainBg)
            if imgui.BeginChild("MainContent", imgui.ImVec2(0, 0), false) then
                -- Padding interno para o conteúdo
                imgui.SetCursorPos(imgui.ImVec2(20, 20))
                
                imgui.TextColored(imgui.ImVec4(1, 1, 1, 1), "Bem-vindo ao Ayze Menu!")
                imgui.Spacing()
                imgui.TextColored(imgui.ImVec4(0.6, 0.6, 0.6, 1), "Aqui ficará o conteúdo das tuas funcionalidades.")
                
                -- Exemplo de Checkbox no conteúdo principal
                imgui.Spacing()
                imgui.SetCursorPosX(20)
                imgui.Checkbox("Funcao de exemplo", fakeBool)
                
                imgui.EndChild()
            end
            imgui.PopStyleColor()

            imgui.End()
        end
        imgui.PopStyleVar()
    end
)

function main()
    if not isSampLoaded() or not isSampfuncsLoaded() then return end
    while not isSampAvailable() do wait(100) end

    sampRegisterChatCommand("ayze", function()
        if isAuthenticated then
            showMainMenu[0] = not showMainMenu[0]
        else
            showAuthWindow[0] = not showAuthWindow[0]
        end
    end)

    -- Heartbeat: revalida a key a cada 60s. Revogou/baniu/expirou/atualizou => bloqueia na hora.
    while true do
        wait(60000)
        if isAuthenticated then
            local r = validateKey(sessionKey, true)
            if r.status ~= "VALIDA" and r.status ~= "ERRO" then
                lockMenu(STATUS_MSG[r.status])
            elseif r.status == "VALIDA" and r.update then
                if downloadUpdate(sessionKey) then thisScript():reload() end
                if r.mandatory then lockMenu("ATUALIZACAO OBRIGATORIA PENDENTE") end
            end
        end
    end
end
