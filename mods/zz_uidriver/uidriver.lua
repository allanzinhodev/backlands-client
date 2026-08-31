-- Dev driver. Watches the write dir for a Lua chunk, runs it, writes the result
-- back. Lets an outside process drive the client without mouse automation,
-- which is 2px away from clicking the wrong widget every single time.
UIDriverDir = '/uidriver'
UIDriverCmd = UIDriverDir .. '/cmd.lua'
UIDriverOut = UIDriverDir .. '/out.txt'
UIDriverEvent = nil

-- Helpers the outside chunks lean on, so each command stays one or two lines.
UID = {}

function UID.root()
  return g_ui.getRootWidget()
end

function UID.find(id)
  return UID.root():recursiveGetChildById(id)
end

function UID.rect(w)
  if type(w) == 'string' then w = UID.find(w) end
  if not w then return nil end
  local p, s = w:getPosition(), w:getSize()
  return p.x, p.y, s.width, s.height
end

-- "x y w h" of a widget, ready to paste into probe.js crop
function UID.box(id)
  local x, y, cw, ch = UID.rect(id)
  if not x then return 'not found: ' .. tostring(id) end
  return string.format('%d %d %d %d', x, y, cw, ch)
end

local function describe(w)
  local p, s = w:getPosition(), w:getSize()
  local id = w:getId() or '?'
  local txt = ''
  if w.getText then
    local ok, t = pcall(function() return w:getText() end)
    if ok and t and #t > 0 then txt = ' "' .. t:gsub('\n', '\\n') .. '"' end
  end
  local font = ''
  if w.getFont then
    local ok, f = pcall(function() return w:getFont() end)
    if ok and f then
      local ok2, n = pcall(function() return f:getName() end)
      if ok2 and n then font = ' font=' .. n end
    end
  end
  return string.format('%s [%s] %d,%d %dx%d%s%s%s', id, w:getClassName(),
    p.x, p.y, s.width, s.height, w:isVisible() and '' or ' HIDDEN', font, txt)
end

-- Recursive dump. Only visible branches by default: an invisible subtree is
-- noise when the question is "what does the player actually see".
function UID.tree(w, maxDepth, showHidden, depth, acc)
  if type(w) == 'string' then w = UID.find(w) end
  if not w then return 'not found' end
  depth = depth or 0
  acc = acc or {}
  maxDepth = maxDepth or 6
  table.insert(acc, string.rep('  ', depth) .. describe(w))
  if depth < maxDepth then
    for _, c in ipairs(w:getChildren()) do
      if showHidden or c:isVisible() then
        UID.tree(c, maxDepth, showHidden, depth + 1, acc)
      end
    end
  end
  if depth == 0 then return table.concat(acc, '\n') end
  return acc
end

-- Top-level widgets currently on screen, in draw order.
function UID.windows()
  local out = {}
  for _, c in ipairs(UID.root():getChildren()) do
    if c:isVisible() then table.insert(out, describe(c)) end
  end
  return table.concat(out, '\n')
end

-- ---------------------------------------------------------------- audit
--
-- The static scan measures declared widths. It cannot see the failure the new
-- font actually causes most often: nothing is *cut*, two widgets simply land on
-- top of each other, because one side is anchored to parent.left and grows into
-- another anchored to parent.right. That only exists once the window is laid
-- out, so the check has to run in here.
--
-- The unit of measure is the "ink box": where the text is really painted, which
-- for a CheckBox is outside its 12x12 rect on purpose (text-offset 18). Judging
-- by the widget rect would flag every checkbox in the client.

-- getTextSize reports the nominal box: silkscreen-16 is 16px tall but almost every
-- glyph stops at row 13 (only Q q & _ , $ | reach 15). Two stacked labels 13px
-- apart therefore look fine and still "intersect" if you trust the nominal box.
-- Three pixels come off the height so the test is about ink, not about padding.
local INK_SLACK = 3

-- Fw::AlignmentFlag, from src/framework/const.h
local ALIGN_LEFT, ALIGN_RIGHT = 1, 2
local ALIGN_TOP, ALIGN_BOTTOM = 4, 8
local ALIGN_HCENTER, ALIGN_VCENTER = 16, 32

-- Where the glyphs really land. drawText() gets m_rect offset by m_textOffset and
-- then the font aligns inside it, so text that is centred does NOT start at
-- rect.x + offset.x - assuming it did put every centred label's box half its own
-- width too far left, and made every ComboBox look like it overflowed.
local function inkBox(w)
  local r = w:getRect()
  local t = w:getText()
  if not t or #t == 0 then return nil end
  local ts = w:getTextSize()
  local off = w:getTextOffset()
  local align = w:getTextAlign()

  -- drawText passes Rect(topLeft + offset, bottomRight): the offset moves the
  -- origin, so the box the font aligns within is narrower by the offset
  local bx, bw = r.x + off.x, r.width - off.x
  local by, bh = r.y + off.y, r.height - off.y

  local function has(flag) return math.floor(align / flag) % 2 == 1 end

  local x
  if has(ALIGN_RIGHT) then x = bx + bw - ts.width
  elseif has(ALIGN_HCENTER) then x = bx + math.floor((bw - ts.width) / 2)
  else x = bx end

  local ih = math.max(1, ts.height - INK_SLACK)
  local y
  if has(ALIGN_BOTTOM) then y = by + bh - ts.height
  elseif has(ALIGN_VCENTER) then y = by + math.floor((bh - ts.height) / 2)
  else y = by end

  return { x = math.floor(x), y = math.floor(y), width = ts.width, height = ih,
           -- the box the font aligns inside; glyphs outside it are clipped away
           clipX = bx, clipY = by, clipW = bw, clipH = bh }
end

local function intersectBox(b, x1, y1, x2, y2)
  local nx1 = math.max(b.x, x1)
  local ny1 = math.max(b.y, y1)
  local nx2 = math.min(b.x + b.width, x2)
  local ny2 = math.min(b.y + b.height, y2)
  return { x = nx1, y = ny1, width = nx2 - nx1, height = ny2 - ny1 }
end

local function intersects(a, b)
  return a.x < b.x + b.width and b.x < a.x + a.width
     and a.y < b.y + b.height and b.y < a.y + a.height
end

local function isRelated(a, b)
  local p = a
  while p do if p == b then return true end p = p:getParent() end
  p = b
  while p do if p == a then return true end p = p:getParent() end
  return false
end

local function paints(w)
  if w:getOpacity() <= 0.05 then return false end
  local t = w:getText()
  if t and #t > 0 then return true end
  local ok, src = pcall(function() return w:getImageSource() end)
  return ok and src and #src > 0
end

-- A widget inside a clipping container (a list, a scroll area) is only painted
-- where the container shows it. Ignoring that reported every row scrolled out of
-- a hotkey list as colliding with the buttons underneath, which is exactly the
-- kind of noise that makes an audit not worth reading.
local function clipRect(w)
  local clip = nil
  local p = w:getParent()
  while p do
    if p:isClipping() then
      local r = p:getRect()
      if not clip then
        clip = { x = r.x, y = r.y, width = r.width, height = r.height }
      else
        local x1 = math.max(clip.x, r.x)
        local y1 = math.max(clip.y, r.y)
        local x2 = math.min(clip.x + clip.width, r.x + r.width)
        local y2 = math.min(clip.y + clip.height, r.y + r.height)
        clip = { x = x1, y = y1, width = math.max(0, x2 - x1), height = math.max(0, y2 - y1) }
      end
    end
    p = p:getParent()
  end
  return clip
end

local function collect(w, acc, depth)
  if depth > 24 or not w:isVisible() then return acc end
  table.insert(acc, w)
  for _, c in ipairs(w:getChildren()) do collect(c, acc, depth + 1) end
  return acc
end

local function path(w, stop)
  local parts = {}
  local p = w
  while p and p ~= stop do
    table.insert(parts, 1, p:getId() or p:getClassName())
    p = p:getParent()
  end
  return table.concat(parts, '/')
end

function UID.audit(win, limit)
  if type(win) == 'string' then win = UID.find(win) end
  if not win then return 'not found' end
  limit = limit or 25

  local all = collect(win, {}, 0)
  local inked = {}
  for _, w in ipairs(all) do
    local raw = inkBox(w)
    if raw and w:getOpacity() > 0.05 then
      -- What is actually painted, in two steps. First the widget's own box:
      -- BitmapFont::calculateDrawTextCoords drops glyphs that fall outside
      -- screenCoords and clamps the ones straddling its edge, so a label can
      -- never paint over its neighbour - it gets CUT instead. Then any clipping
      -- ancestor (a list, a scroll area) trims what is left.
      local b = intersectBox(raw, raw.clipX, raw.clipY,
                             raw.clipX + raw.clipW, raw.clipY + raw.clipH)
      local clip = clipRect(w)
      if clip then
        b = intersectBox(b, clip.x, clip.y, clip.x + clip.width, clip.y + clip.height)
      end
      -- Widget de 1 ou 2 pixels nao mostra texto a ninguem: e guardador de valor
      -- invisivel, como o spinBox de 1x1 do CountWindow. Reclamar dele e ruido.
      if b.width > 3 and b.height > 3 then
        table.insert(inked, { w = w, box = b, raw = raw, clip = clip })
      end
    end
  end

  local out = {}
  local pad = win:getPaddingRect()

  -- 1. text painted outside the window's own content area.
  -- The window's own title is exempt: it is drawn in the title band, which is
  -- above the padding rect by design.
  for _, e in ipairs(inked) do
    local b = e.box
    if e.w ~= win then
      if b.x + b.width > pad.x + pad.width + 1 or b.x < pad.x - 1 then
        table.insert(out, string.format('ESCAPA  %s "%s" ink x=%d..%d vs janela %d..%d',
          path(e.w, win), e.w:getText(), b.x, b.x + b.width, pad.x, pad.x + pad.width))
      elseif b.y + b.height > pad.y + pad.height + 1 then
        table.insert(out, string.format('ESCAPA-Y %s "%s" ink y=%d..%d vs janela ..%d',
          path(e.w, win), e.w:getText(), b.y, b.y + b.height, pad.y + pad.height))
      end
    end
    if #out >= limit then break end
  end

  -- 2. text painted outside the widget that holds it. Comparing the text width
  -- against `width - |text-offset|` is a heuristic and it lies: a ComboBox centres
  -- its text and shifts it left by 10 to clear the arrow, so it runs out through
  -- the LEFT edge while that formula still says it fits. Measuring where the ink
  -- lands against the widget's own rect needs no per-class knowledge and catches
  -- both directions.
  --
  -- The exception is the checkbox idiom: `size: 12 12` with `text-offset: 18`
  -- puts the caption beside the box on purpose. It reads as text-offset.x
  -- reaching past the widget's own width.
  for _, e in ipairs(inked) do
    local w = e.w
    local raw = e.raw
    if w ~= win and not w:getTextWrap() and w:getWidth() > 0
       and w:getTextOffset().x < w:getWidth() then
      local cutLeft = raw.clipX - raw.x
      local cutRight = (raw.x + raw.width) - (raw.clipX + raw.clipW)
      if cutLeft > 1 or cutRight > 1 then
        table.insert(out, string.format('ESTOURA %s "%s" texto %dpx em %dpx (corta %d esq, %d dir)',
          path(w, win), w:getText(), raw.width, raw.clipW,
          math.max(0, cutLeft), math.max(0, cutRight)))
      end
    end
    if #out >= limit then break end
  end

  -- 3. wrapped text taller than the box holding it. text-wrap trades width for
  -- height, so the overflow moves to an axis nothing else here looks at: the
  -- widget measures fine horizontally and still loses its last line.
  for _, e in ipairs(inked) do
    local w = e.w
    if w ~= win and w:getTextWrap() then
      local r = w:getRect()
      local ts = w:getTextSize()
      if ts.height > r.height + 1 then
        table.insert(out, string.format('ALTURA %s "%s" texto quebrado ocupa %dpx em %dpx',
          path(w, win), (w:getText()):gsub('\n', ' / '), ts.height, r.height))
      end
    end
    if #out >= limit then break end
  end

  -- 4. a direct child whose rect leaves the window's content area. Text-only
  -- checks miss this: a button or a panel can hang out the bottom while every
  -- label inside it still measures fine.
  for _, c in ipairs(win:getChildren()) do
    -- A phantom decoration hanging over the frame is an idiom of this skin, not a
    -- defect: the crest sits above the title bar on the login panel and on every
    -- window that uses backdrop_crestr, anchored with a negative margin on purpose.
    if c:isVisible() and not c:isPhantom() then
      local r = c:getRect()
      local dx = (r.x + r.width) - (pad.x + pad.width)
      local dy = (r.y + r.height) - (pad.y + pad.height)
      if dy > 1 or dx > 1 or r.x < pad.x - 1 or r.y < pad.y - 1 then
        table.insert(out, string.format('SAI-RECT %s rect %d,%d %dx%d vs area %d,%d %dx%d (excede x%d y%d)',
          tostring(c:getId()), r.x, r.y, r.width, r.height,
          pad.x, pad.y, pad.width, pad.height, math.max(0, dx), math.max(0, dy)))
      end
    end
    if #out >= limit then break end
  end

  -- 4. two texts painted on top of each other
  for i = 1, #inked do
    for j = i + 1, #inked do
      local a, b = inked[i], inked[j]
      if not isRelated(a.w, b.w) and intersects(a.box, b.box) and paints(a.w) and paints(b.w) then
        table.insert(out, string.format('COLIDE  %s "%s"  X  %s "%s"',
          path(a.w, win), a.w:getText(), path(b.w, win), b.w:getText()))
      end
      if #out >= limit then break end
    end
    if #out >= limit then break end
  end

  -- 5. text buried under a panel drawn later.
  --
  -- COLIDE so compara texto com texto, e por isso nao viu o painel de ofertas do
  -- Market cobrir o botao "2H" e metade de "Show Locker only". Nao e caso raro: a
  -- fonte nova alarga o widget de texto, ele avanca sobre a coluna vizinha, e a
  -- coluna vizinha e um painel opaco desenhado depois - some sem deixar rastro em
  -- nenhuma das outras quatro checagens.
  --
  -- `all` esta em ordem de desenho (pre-ordem da arvore), entao "desenhado depois"
  -- e so indice maior. So conta painel opaco, nao-phantom e com imagem propria:
  -- overlay de scanline, realce e moldura sao idioma desta skin.
  local ordem = {}
  for i, w in ipairs(all) do ordem[w] = i end
  for _, e in ipairs(inked) do
    local iTexto = ordem[e.w]
    for _, c in ipairs(all) do
      local j = ordem[c]
      if j > iTexto and not isRelated(e.w, c) and not c:isPhantom() and c:getOpacity() > 0.9 then
        local okSrc, src = pcall(function() return c:getImageSource() end)
        if okSrc and src and #src > 0 then
          local r = c:getRect()
          local x1 = math.max(e.box.x, r.x)
          local x2 = math.min(e.box.x + e.box.width, r.x + r.width)
          local y1 = math.max(e.box.y, r.y)
          local y2 = math.min(e.box.y + e.box.height, r.y + r.height)
          local coberto = math.max(0, x2 - x1) * math.max(0, y2 - y1)
          if coberto > e.box.width * e.box.height * 0.25 then
            table.insert(out, string.format('TAPADO  %s "%s" coberto por %s (%d%% do texto)',
              path(e.w, win), e.w:getText(), path(c, win),
              math.floor(coberto / (e.box.width * e.box.height) * 100)))
            break
          end
        end
      end
    end
    if #out >= limit then break end
  end

  if #out == 0 then return 'limpo (' .. #all .. ' widgets, ' .. #inked .. ' com texto)' end
  return string.format('%d achados em %d widgets:\n', #out, #all) .. table.concat(out, '\n')
end

-- One-shot: authenticate, wait for the character list to actually exist, pick a
-- character by name and enter the world. The list only appears after a server
-- round-trip, so this polls instead of assuming.
function UID.enter(acc, pass, charName)
  UID.enterState = 'authenticating'
  EnterGame.doLogin(acc, pass)
  local tries = 0
  local tick
  tick = function()
    tries = tries + 1
    if g_game.isOnline() then UID.enterState = 'online' return end
    if tries > 60 then UID.enterState = 'timeout' return end
    local win = UID.find('charactersWindow')
    local list = win and win:recursiveGetChildById('characters')
    if list and #list:getChildren() > 0 then
      for _, c in ipairs(list:getChildren()) do
        local n = c.characterName or (c:getChildById('name') and c:getChildById('name'):getText())
        if n and tostring(n):lower():find(tostring(charName):lower(), 1, true) then
          list:focusChild(c)
          UID.enterState = 'entering ' .. tostring(n)
          CharacterList.doLogin()
          scheduleEvent(tick, 500)
          return
        end
      end
      UID.enterState = 'character not in list'
      return
    end
    scheduleEvent(tick, 500)
  end
  scheduleEvent(tick, 500)
  return 'started'
end

local function reply(text)
  g_resources.writeFileContents(UIDriverOut, tostring(text))
end

local function poll()
  if not g_resources.fileExists(UIDriverCmd) then return end
  local src = g_resources.readFileContents(UIDriverCmd)
  g_resources.deleteFile(UIDriverCmd)
  if not src or #src == 0 then return end

  local chunk, err = loadstring(src, '@uidriver')
  if not chunk then
    reply('COMPILE-ERROR ' .. tostring(err))
    return
  end
  local ok, res = pcall(chunk)
  if ok then
    reply('OK ' .. tostring(res))
  else
    reply('ERROR ' .. tostring(res))
  end
end

function UIDriver_init()
  g_resources.makeDir(UIDriverDir)
  reply('READY')
  UIDriverEvent = cycleEvent(poll, 250)
end

function UIDriver_terminate()
  if UIDriverEvent then UIDriverEvent:cancel() end
  UIDriverEvent = nil
end

-- Quais widgets com texto ainda NAO estao na silkscreen.
--
-- O Lua deste fork nao expoe nome de fonte (getFont() devolve algo sem getName),
-- entao a fonte se descobre medindo: joga o mesmo texto num widget que
-- comprovadamente usa $var-cip-font e compara a largura. Fonte diferente, largura
-- diferente - e nao ha falso positivo possivel, porque e a metrica real do atlas.
function UID.fontaudit(win, limit)
  if type(win) == 'string' then win = UID.find(win) end
  if not win then return 'not found' end
  limit = limit or 30

  -- sonda: um widget silkscreen que nao esta na tela
  local probe = g_ui.createWidget('UIWidget', UID.root())
  probe:setFont('silkscreen-16')
  probe:setVisible(false)

  local out, seen = {}, {}
  local function walk(w, d)
    if d > 24 or not w:isVisible() or #out >= limit then return end
    local t = w:getText()
    -- text-wrap muda o que getTextSize devolve (a caixa JA quebrada), entao a
    -- comparacao com a sonda, que nao quebra, nao diz nada sobre a fonte
    if t and #t > 0 and not t:find('\n') and not w:getTextWrap() then
      probe:setText(t)
      local mine, silk = w:getTextSize().width, probe:getTextSize().width
      if mine ~= silk then
        local key = tostring(w:getId()) .. '|' .. t
        if not seen[key] then
          seen[key] = true
          table.insert(out, string.format('%-28s %4dpx (silkscreen daria %4d)  [%s]',
            tostring(w:getId()), mine, silk, t))
        end
      end
    end
    for _, c in ipairs(w:getChildren()) do walk(c, d + 1) end
  end
  walk(win, 0)
  probe:destroy()

  if #out == 0 then return 'tudo em silkscreen' end
  return string.format('%d widgets fora da silkscreen:\n', #out) .. table.concat(out, '\n')
end