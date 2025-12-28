--[=====[
[[SND Metadata]]
author:  'Tomatokun P.'
version: 0.1.2

description: HTA準拠 HuntTrain Driver (SND Lua) - 原型 + Flag/Instance parser + SND GUI configs

plugin_dependencies:
- SomethingNeedDoing
- vnavmesh
- Lifestream

configs:
  有効:
    default: true
    description: スクリプト全体の有効/無効

  デバッグログ:
    default: true
    description: /xllog に詳細ログを出す

  コンダクター名:
    default: "Tomatokun Pomodoro"
    description: フラグを採用する送信者名（完全一致）。複数はカンマ区切り

  フラグ連投抑止(秒):
    default: 1.0
    description: 連続チャット処理の最小間隔（確定時に適用）

  フラグマージ猶予(秒):
    default: 2.0
    description: <flag> と ins 指示が別メッセージの場合に合体させる猶予

  重複フラグ距離閾値:
    default: 10.0
    description: 近すぎるフラグを重複として無視する距離（HTA準拠=10）

  到着許容距離:
    default: 3.0
    description: vnavmesh の許容誤差（目標到達とみなす距離）

  vnavmeshを使う:
    default: true
    description: vnavmeshで移動する

  飛行:
    default: false
    description: vnavmeshのflyフラグ

  インスタンス検出:
    default: true
    description: ins1 / instance1 / インスタンス1 等をメッセージから拾う

  エリア別インスタンス数:
    default: "リビング・メモリー=3"
    description: 地名=数 をカンマ区切り。未登録は0扱い（インスタ無し）

  ins未指定時に巡回:
    default: true
    description: インスタンス有りエリアで、ins指定が無い場合に 1→2→3…巡回

  RSRを使う:
    default: false
    description: ホワイトリストモブ検知時にRSRをON（RSRが無い環境だと起動すらできないのでデフォルトfalse）

  モブ検知半径:
    default: 90.0
    description: ホワイトリストモブ検知距離

  モブホワイトリスト:
    default: "プギル"
    description: カンマ区切り（暫定：CURRENTのみ）

[[End Metadata]]
--]=====]

import("System")
import("System.Numerics")

-- ============================================================
-- 0) 設定読込（SND GUI configs）
-- ============================================================
local function cfg_bool(name, fallback)
  local v = Config.Get(name)
  if v == nil then return fallback end
  return v == true
end

local function cfg_num(name, fallback)
  local v = Config.Get(name)
  v = tonumber(v)
  if v == nil then return fallback end
  return v
end

local function cfg_str(name, fallback)
  local v = Config.Get(name)
  if v == nil then return fallback end
  return tostring(v)
end

local function split_csv(s)
  local out = {}
  if not s or s == "" then return out end
  for part in tostring(s):gmatch("[^,]+") do
    local t = part:gsub("^%s+", ""):gsub("%s+$", "")
    if t ~= "" then table.insert(out, t) end
  end
  return out
end

local function parse_area_instances(s)
  local map = {}
  for _, item in ipairs(split_csv(s)) do
    local k, v = item:match("^(.+)%=(%d+)$")
    if k and v then
      k = k:gsub("^%s+", ""):gsub("%s+$", "")
      map[k] = tonumber(v)
    end
  end
  return map
end

local CFG = {
  Enabled = cfg_bool("有効", true),
  Debug = cfg_bool("デバッグログ", true),

  DuplicateDistanceThreshold = cfg_num("重複フラグ距離閾値", 10.0),
  ArriveTolerance = cfg_num("到着許容距離", 3.0),
  MobScanRadius = cfg_num("モブ検知半径", 90.0),
  FlagThrottleSec = cfg_num("フラグ連投抑止(秒)", 1.0),
  MergeWindowSec = cfg_num("フラグマージ猶予(秒)", 2.0),

  UseNav = cfg_bool("vnavmeshを使う", true),
  Fly = cfg_bool("飛行", false),

  UseInstanceDetect = cfg_bool("インスタンス検出", true),
  CycleInstancesWhenUnspecified = cfg_bool("ins未指定時に巡回", true),

  UseRSR = cfg_bool("RSRを使う", false),
}

local CONDUCTORS = split_csv(cfg_str("コンダクター名", "Tomatokun Pomodoro"))
local AREA_INSTANCES = parse_area_instances(cfg_str("エリア別インスタンス数", "リビング・メモリー=3"))
local MOBS_BY_TERRITORY = { CURRENT = split_csv(cfg_str("モブホワイトリスト", "プギル")) }

-- ============================================================
-- 1) ログ
-- ============================================================
local function log(msg)
  if CFG.Debug then
    Dalamud.Log("[HTA-LUA] " .. tostring(msg))
  end
end

local function now_sec()
  return os.clock()
end

local function contains(tbl, v)
  for _, x in ipairs(tbl) do
    if x == v then return true end
  end
  return false
end

local function dist3(a, b)
  local dx = (a.x or 0) - (b.x or 0)
  local dy = (a.y or 0) - (b.y or 0)
  local dz = (a.z or 0) - (b.z or 0)
  return math.sqrt(dx*dx + dy*dy + dz*dz)
end

-- ============================================================
-- 2) APIラッパ（vnavmeshはFishing準拠）
-- ============================================================
local API = {}

API.Player = {
  IsAvailable = function()
    return Player and Player.Available == true
  end,
}

API.Nav = {
  IsReady = function()
    return IPC and IPC.vnavmesh and IPC.vnavmesh.IsReady and IPC.vnavmesh.IsReady() or false
  end,
  Stop = function()
    if IPC and IPC.vnavmesh and IPC.vnavmesh.Stop then IPC.vnavmesh.Stop() end
  end,
  SetTolerance = function(t)
    if IPC and IPC.vnavmesh and IPC.vnavmesh.PathSetTolerance then
      IPC.vnavmesh.PathSetTolerance(t)
    end
  end,
  MoveTo = function(vec3, fly)
    if IPC and IPC.vnavmesh and IPC.vnavmesh.PathfindAndMoveTo then
      IPC.vnavmesh.PathfindAndMoveTo(vec3, fly == true)
    end
  end,
  WaitUntilDone = function(waitSec)
    waitSec = waitSec or 0.2
    while IPC and IPC.vnavmesh and (IPC.vnavmesh.PathfindInProgress() or IPC.vnavmesh.IsRunning()) do
      yield(string.format("/wait %.1f", waitSec))
    end
  end,
}

API.World = {
  DoesObjectExist = function(name)
    local e = Entity and Entity.GetEntityByName and Entity.GetEntityByName(name) or nil
    return e ~= nil and e.IsValid == true
  end,
  GetDistanceToObject = function(name)
    local e = Entity and Entity.GetEntityByName and Entity.GetEntityByName(name) or nil
    if e and e.IsValid and Player and Player.Entity and Player.Entity.Position and e.Position then
      local p = Player.Entity.Position
      local q = e.Position
      return math.sqrt((p.X-q.X)^2 + (p.Y-q.Y)^2 + (p.Z-q.Z)^2)
    end
    return 9999
  end,
}

API.RSR = {
  SetEnabled = function(enabled)
    log("RSR " .. (enabled and "ON" or "OFF"))
  end
}

-- ============================================================
-- 3) 解析（<flag> / ins）
-- ============================================================
local function parse_flag_text(msg)
  if not msg or msg == "" then return nil end
  local x, y = msg:match("%(%s*([%d%.]+)%s*,%s*([%d%.]+)%s*%)")
  if not x or not y then x, y = msg:match("%(%s*([%d%.]+)%s*，%s*([%d%.]+)%s*%)") end

  local place = msg:match("^(.-)%s*%(")
  if place then
    place = place:gsub("%s+$", ""):gsub("^", "")
  else
    place = msg
  end

  if x and y then return { place = place, x = tonumber(x), y = tonumber(y), raw = msg } end
  return nil
end

local function parse_instance_text(msg)
  if not msg or msg == "" then return nil end
  local m = msg:lower()
  local n = m:match("ins%s*(%d+)")
  if not n then n = m:match("instance%s*(%d+)") end
  if not n then n = msg:match("インスタンス%s*(%d+)") end
  if not n then n = msg:match("インスタ%s*(%d+)") end
  if not n then
    local circ = msg:match("[①②③④⑤]")
    if circ then
      local map = { ["①"]=1,["②"]=2,["③"]=3,["④"]=4,["⑤"]=5 }
      return map[circ]
    end
  end
  if n then return tonumber(n) end
  return nil
end

-- ★SetFlagMapMarker は Instances.Map.Flag 側
local function Map_GetFlagVector3()
  if not (Instances and Instances.Map and Instances.Map.Flag) then return nil end
  return Instances.Map.Flag.Vector3
end

local function Map_SetFlag(mapX, mapY)
  if not (Instances and Instances.Map and Instances.Map.Flag) then
    log("ERROR: Instances.Map.Flag not ready")
    return false, "not_ready"
  end
  local flag = Instances.Map.Flag
  local territoryId = tonumber(flag.TerritoryId)
  local mapId = tonumber(flag.MapId)

  if CFG.Debug then
    log(string.format("SetFlag call: territoryId=%s mapId=%s x=%.1f y=%.1f", tostring(territoryId), tostring(mapId), mapX, mapY))
  end

  local ok, err = pcall(function()
    if territoryId and mapId then
      flag:SetFlagMapMarker(territoryId, mapId, mapX, mapY)
      return
    end
    if territoryId then
      flag:SetFlagMapMarker(territoryId, mapX, mapY)
      return
    end
    error("territoryId is nil")
  end)

  if not ok then
    log("SetFlagMapMarker pcall failed: " .. tostring(err))
    return false, tostring(err)
  end

  -- Vector3反映待ち（メインループから呼ばれる前提なので yield OK）
  local waited = 0
  while waited < 0.5 do
    local v3 = Map_GetFlagVector3()
    if v3 and (v3.X ~= 0 or v3.Z ~= 0) then
      return true, "ok"
    end
    yield("/wait 0.05")
    waited = waited + 0.05
  end
  return false, "vector3_nil"
end

-- ============================================================
-- 4) ランタイム
-- ============================================================
local STATE = {
  WAIT_FLAG = "WAIT_FLAG",
  PLAN_MOVE = "PLAN_MOVE",
  MOVE_DIRECT = "MOVE_DIRECT",
  ARRIVED_CHECK = "ARRIVED_CHECK",
  COMBAT_RSR_ON = "COMBAT_RSR_ON",
  WAIT_AT_SPOT = "WAIT_AT_SPOT",
}

local state = STATE.WAIT_FLAG
local flag = nil
local lastFlag = nil
local lastFlagAcceptedAt = 0
local rsrEnabled = false

local pending = { sender=nil, flag=nil, instance=nil, at=0, commitRequested=false }
local areaCycle = {}

local function area_instance_count(place)
  if not place then return 0 end
  return AREA_INSTANCES[place] or 0
end

local function next_cycle_instance(place)
  local n = area_instance_count(place)
  if n <= 1 then return nil end
  local cur = areaCycle[place] or 1
  local nxt = cur + 1
  if nxt > n then nxt = 1 end
  areaCycle[place] = nxt
  return nxt
end

local function is_duplicate_flag(newFlag)
  if not lastFlag then return false end
  if newFlag.territoryKey ~= lastFlag.territoryKey then return false end
  local d = dist3(newFlag.world, lastFlag.world)
  log("DuplicateCheck distance=" .. tostring(d))
  return d <= CFG.DuplicateDistanceThreshold
end

local function accept_flag(newFlag)
  flag = newFlag
  lastFlagAcceptedAt = now_sec()
  lastFlag = newFlag

  if rsrEnabled and CFG.UseRSR then
    API.RSR.SetEnabled(false)
    rsrEnabled = false
  end
  if CFG.UseNav then
    API.Nav.Stop()
  end

  state = STATE.PLAN_MOVE
  log(string.format("Flag accepted: place=%s (%.1f,%.1f) ins=%s", tostring(newFlag.place), newFlag.mapX, newFlag.mapY, tostring(newFlag.instance)))
end

local function build_flag(sender, place, mapX, mapY, instance)
  local ok, reason = Map_SetFlag(mapX, mapY)
  log("SetFlagMapMarker -> " .. tostring(ok) .. (reason and (" ("..tostring(reason)..")") or ""))

  if not ok then
    log("ERROR: SetFlagMapMarker failed / not available")
    return nil
  end

  local v = Map_GetFlagVector3()
  if not v then
    log("ERROR: Map.Flag.Vector3 is nil")
    return nil
  end

  local world = { x = v.X, y = v.Y, z = v.Z }

  if CFG.Debug then
    log(string.format("DBG map_to_world: map=(%.1f,%.1f) world=(%.3f,%.3f,%.3f)", mapX, mapY, world.x, world.y, world.z))
  end

  return {
    sender = sender,
    raw = string.format("%s (%.1f, %.1f)", tostring(place), mapX, mapY),
    territoryKey = "CURRENT",
    place = place,
    instance = instance or 0,
    mapX = mapX,
    mapY = mapY,
    world = world,
  }
end

local function clear_pending()
  pending.sender=nil; pending.flag=nil; pending.instance=nil; pending.at=0; pending.commitRequested=false
end

local function try_commit_pending(force)
  if not pending.flag then return end

  local age = now_sec() - (pending.at or 0)
  if not force and not pending.commitRequested and age < CFG.MergeWindowSec then
    return
  end

  local t = now_sec()
  if (t - lastFlagAcceptedAt) < CFG.FlagThrottleSec then
    return
  end

  local f = pending.flag
  local ins = pending.instance
  local instCount = area_instance_count(f.place)

  if (not ins) and instCount >= 2 and CFG.CycleInstancesWhenUnspecified then
    ins = next_cycle_instance(f.place) or 1
  end

  local newFlag = build_flag(pending.sender, f.place, f.x, f.y, ins)
  if not newFlag then
    log("Flag build failed (newFlag=nil)")
    clear_pending()
    return
  end

  if is_duplicate_flag(newFlag) then
    log("Flag ignored (duplicate)")
  else
    accept_flag(newFlag)
  end

  clear_pending()
end

local function ingest_chat(senderName, messageText)
  if not CFG.Enabled then return end
  if #CONDUCTORS > 0 and not contains(CONDUCTORS, senderName) then return end

  local f = parse_flag_text(messageText)
  local ins = CFG.UseInstanceDetect and parse_instance_text(messageText) or nil

  if f then
    log(string.format("FLAG候補: place=%s (%.1f,%.1f)", tostring(f.place), f.x, f.y))
    pending.sender = senderName
    pending.flag = f
    pending.at = now_sec()
    pending.commitRequested = false
    if ins then
      pending.instance = ins
      pending.commitRequested = true
    end
    return
  end

  if ins then
    log("INS候補: " .. tostring(ins))
    pending.sender = pending.sender or senderName
    pending.instance = ins
    if pending.at == 0 then pending.at = now_sec() end
    if pending.flag then pending.commitRequested = true end
    return
  end
end

-- ============================================================
-- 5) モブ判定
-- ============================================================
local function find_whitelisted_mob(territoryKey, radius)
  local wl = MOBS_BY_TERRITORY[territoryKey] or {}
  for _, name in ipairs(wl) do
    if API.World.DoesObjectExist(name) then
      local d = API.World.GetDistanceToObject(name)
      if d and d <= radius then return name, d end
    end
  end
  return nil, nil
end

-- ============================================================
-- 6) State処理
-- ============================================================
local function handle_wait_flag()
  try_commit_pending(false)
end

local function handle_plan_move()
  if not flag then state = STATE.WAIT_FLAG return end
  state = STATE.MOVE_DIRECT
end

local function handle_move_direct()
  if not flag then state = STATE.WAIT_FLAG return end
  if not CFG.UseNav then state = STATE.ARRIVED_CHECK return end
  if not API.Nav.IsReady() then return end

  API.Nav.SetTolerance(CFG.ArriveTolerance)

  local v3 = Map_GetFlagVector3()
  if not v3 then
    log("Flag.Vector3 is nil (maybe map not ready yet)")
    return
  end

  log(string.format("Nav move-to Flag.Vector3 = <%.3f, %.3f, %.3f>", v3.X, v3.Y, v3.Z))
  API.Nav.MoveTo(v3, CFG.Fly)
  API.Nav.WaitUntilDone(0.2)
  state = STATE.ARRIVED_CHECK
end

local function handle_arrived_check()
  if not flag then state = STATE.WAIT_FLAG return end
  local mobName, mobDist = find_whitelisted_mob(flag.territoryKey, CFG.MobScanRadius)
  if mobName then
    log("Whitelisted mob found: " .. mobName .. " dist=" .. tostring(mobDist))
    state = STATE.COMBAT_RSR_ON
  else
    log("No whitelisted mob nearby -> WAIT")
    state = STATE.WAIT_AT_SPOT
  end
end

local function handle_combat_rsr_on()
  if CFG.UseRSR and not rsrEnabled then
    API.RSR.SetEnabled(true)
    rsrEnabled = true
  end
end

local function handle_wait_at_spot()
  try_commit_pending(false)
end

local function tick()
  if not CFG.Enabled then return end
  if not API.Player.IsAvailable() then return end

  if state == STATE.WAIT_FLAG then handle_wait_flag()
  elseif state == STATE.PLAN_MOVE then handle_plan_move()
  elseif state == STATE.MOVE_DIRECT then handle_move_direct()
  elseif state == STATE.ARRIVED_CHECK then handle_arrived_check()
  elseif state == STATE.COMBAT_RSR_ON then handle_combat_rsr_on()
  elseif state == STATE.WAIT_AT_SPOT then handle_wait_at_spot()
  else state = STATE.WAIT_FLAG end
end

-- ============================================================
-- 7) SND Trigger: OnChatMessage
-- ============================================================
function OnChatMessage()
  if not TriggerData then return end
  local sender = TriggerData.sender or ""
  local message = TriggerData.message or ""
  local type_ = TriggerData.type

  if CFG.Debug then
    log(("CHAT: sender=%s type=%s msg=%s"):format(tostring(sender), tostring(type_), tostring(message)))
  end

  -- ★重要：OnChatMessage では yield しない
  ingest_chat(sender, message)
end

-- ============================================================
-- 8) 常駐ループ
-- ============================================================
log("start (waiting chat)")
while CFG.Enabled do
  tick()
  yield("/wait 0.1")
end

-- ============================================================
-- 9) 手動デバッグ
-- ============================================================
function DebugInject(text)
  ingest_chat(CONDUCTORS[1] or "DEBUG", text)
  pending.commitRequested = true
end
