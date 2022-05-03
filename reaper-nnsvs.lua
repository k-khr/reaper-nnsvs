-- ===== Configurable settings =====
-- Name of pretrained model defined at https://github.com/r9y9/nnsvs/blob/a3b4dfba91de42970b2082f872ececd52d82b219/nnsvs/pretrained/__init__.py#L14-L46
pretrained_model = "r9y9/kiritan_latest"
-- Python executable path
python_path = "C:\\Users\\Kihara\\miniconda3\\envs\\nnsvs\\python.exe"
-- Directory to which this script writes
write_dir = nil


--[[
nnsvs.lua
  This script renders a MIDI active take into a synthesized vocal by NNSVS.

Prerequisites:
  Python and libraries (numpy, nnsvs, pysinsy, nnmnkwii)
  For conda users, use `conda env create -n nnsvs.yml`.
]]


-- lazy static variables which will be set in functions
sep = "\\"
bpm = 120
ppq = 960

-- get directory to save xml and wav
function get_write_dir()
  local proj_path = reaper.GetProjectPath()

  local home = os.getenv("USERPROFILE")
  if home == nil then
    sep = "/"
    home = os.getenv("HOME")
  end

  -- Default path "~/Documents/REAPER Media"
  local default_dir = home .. sep .. "Documents" .. sep .. "REAPER Media"

  if write_dir ~= nil then
    return write_dir
  elseif proj_path:len() > 0 then
    return proj_path
  end

  return default_dir
end

-- get a note pitch from a MIDI note number
__gnp_step_tbl = {'C', 'C', 'D', 'D', 'E', 'F', 'F', 'G', 'G', 'A', 'A', 'B'}
__gnp_alt_tbl  = {0, 1, 0, 1, 0, 0, 1, 0, 1, 0, 1, 0}
function get_note_pitch(note_no)
  local rem = (note_no % 12) + 1
  local step = __gnp_step_tbl[rem]
  local alter = __gnp_alt_tbl[rem]
  local octave = (note_no // 12) - 1
  return step, alter, octave
end


write_dir = get_write_dir()
--[[
TODO: get take from selected items
MediaItem       reaper.GetSelectedMediaItem(ReaProject proj, integer selitem)
MediaItem_Take  reaper.GetTake(MediaItem item, integer takeidx)
]]
take = reaper.MIDIEditor_GetTake(reaper.MIDIEditor_GetActive())
retval, midi_evts = reaper.MIDI_GetAllEvts(take, "")
item = reaper.GetMediaItemTakeInfo_Value(take, 'P_ITEM')
item_pos = reaper.GetMediaItemInfo_Value(item, 'D_POSITION')
item_len = reaper.GetMediaItemInfo_Value(item, 'D_LENGTH')
-- TODO: This doesnt work well in anything but /4 time signature
bpm = reaper.TimeMap_GetDividedBpmAtTime(item_pos)
item_bar_start = 1. + item_pos * 60. / bpm
item_bar_end = item_bar_start + item_len * 60. / bpm
-- Get ppq. see https://forums.cockos.com/showpost.php?p=2485876&postcount=2
offset   = reaper.GetMediaItemTakeInfo_Value(take, 'D_STARTOFFS')
qn = reaper.TimeMap2_timeToQN(nil, item_pos - offset)
ppq = reaper.MIDI_GetPPQPosFromProjQN(take, qn + 1)

if not(retval) or midi_evts:len() == 0 then
  reaper.ShowMessageBox("Failed to read MIDI events", "Error", 0)
end

-- note informations
note_no = {}
duration = {}
velocity = {}
on_note = {}
position = {}
tick = {}
lyrics = {}

-- read MIDI events
ticks = 0
cursor = 1
while cursor < midi_evts:len() do
  offset, flags, msg, cursor = string.unpack("i4Bs4", midi_evts, cursor)
  ticks = ticks + offset
  -- note on (ignore channels)
  if msg:byte(1) >> 4 == 9 then
    idx = #note_no + 1
    note_no[idx] = msg:byte(2)
    duration[idx] = ticks
    velocity[idx] = msg:byte(3)
    on_note[msg:byte(2)] = idx
    -- TODO: This doesnt work well in anything but /4 time signature
    pos_fp = 1. + ticks / (ppq * 4.)
    bar = math.floor(pos_fp)
    beat = 1. + math.floor((pos_fp - bar) / 0.25)
    position[idx] = string.format("%d.%.2f", bar, beat)
    tick[idx] = ticks
  -- note off
  elseif msg:byte(1) >> 4 == 8 then
    idx = on_note[msg:byte(2)]
    duration[idx] = ticks - duration[idx]
  else
    -- 
  end
end


-- read lyrics
pos_idx = {}
for i=1,#position do
  pos_idx[position[i]] = i
end
track = reaper.GetSelectedTrack(0, 0)
retval, lyricsbuf = reaper.GetTrackMIDILyrics(track, 2)
if retval then
  for p, lyr in string.gmatch(lyricsbuf, "([%d%.]+)\t([^\t]+)\t") do
    local idx = pos_idx[p]
    if idx ~= nil then
      lyrics[idx] = lyr
    end
  end
end


-- write XML
write_file = write_dir .. sep .. os.date("%Y%m%d_%H%M%S")
f = io.open(write_file .. ".xml", "w")
f:write([[
<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<!DOCTYPE score-partwise PUBLIC "-//Recordare//DTD MusicXML 3.0 Partwise//EN" "http://www.musicxml.org/dtds/partwise.dtd">
<score-partwise version="3.0">
  <part-list>
  <score-part id="P1">
    <part-name>Track 1</part-name>
    <score-instrument id="P1-C1">
      <instrument-name>channel 1</instrument-name>
    </score-instrument>
    <midi-instrument id="P1-C1">
      <midi-channel>1</midi-channel>
    </midi-instrument>
  </score-part>
  </part-list>
  <part id="P1">
]])
ticks = 0
cursor = 1
for b=1,bar do
  f:write(string.format('<measure number="%d">\n', b))
  f:write(string.format('<attributes>\n<divisions>%d</divisions>\n</attributes>\n', ppq))
  -- TODO: This doesnt work well in anything but /4 time signature
  f:write(string.format('<direction>\n<sound tempo="%d"/>\n</direction>\n', bpm))
  -- write notes
  local cnt = 0
  while cursor <= #position and string.find(position[cursor], string.format("%d.", b)) == 1 do
    -- insert rest
    if tick[cursor] > ticks then
      f:write(string.format('<note>\n<rest/>\n<duration>%d</duration>\n</note>\n', tick[cursor] - ticks))
    end
    step, alter, octave = get_note_pitch(note_no[cursor])
    f:write('<note>\n')
    f:write('<pitch>\n')
    f:write(string.format('<step>%s</step>\n', step))
    f:write(string.format('<octave>%d</octave>\n', octave))
    if alter ~= 0 then
      f:write(string.format('<alter>%d</alter>\n', alter))
    end
    f:write('</pitch>\n')
    f:write(string.format('<duration>%d</duration>\n', duration[cursor]))
    f:write('<voice>1</voice>\n')
    -- f:write('<velocity></velocity>\n')
    f:write('<lyric>\n')
    f:write(string.format('<text>%s</text>\n', lyrics[cursor]))
    f:write('</lyric>\n')
    f:write('</note>\n')
    ticks = tick[cursor] + duration[cursor]
    cursor = cursor + 1
    cnt = cnt + 1
  end
  -- whole rest
  if cnt == 0 then
    -- TODO: This doesnt work well in anything but /4 time signature
    f:write(string.format('<note>\n<rest/>\n<duration>%d</duration>\n</note>\n', ppq * 4))
    ticks = ticks + ppq * 4
  end
  f:write('</measure>\n') -- <measure>
end
f:write([[
  </part>
</score-partwise>
]])
f:close()


-- write python file
f = io.open(write_file .. ".py", "w")
f:write(string.format([[
import wave
import numpy as np
import pysinsy
from nnmnkwii.io import hts
import nnsvs
from nnsvs.pretrained import create_svs_engine

engine = create_svs_engine(r"%s")

contexts = pysinsy.extract_fullcontext(r"%s.xml")
labels = hts.HTSLabelFile.create_from_contexts(contexts)
wav, sr = engine.svs(labels)
wav = np.atleast_2d(wav)
w = wave.Wave_write(r"%s.wav")
w.setparams((wav.shape[0], wav.itemsize, sr, wav.shape[1], 'NONE', 'not compressed'))
w.writeframes(wav)
]], pretrained_model, write_file, write_file))
f:close()

os.execute(python_path .. " " .. write_file .. ".py")

f = io.open(write_file..".wav")
if f ~= nil then
  f:close()
  reaper.Undo_BeginBlock2(0)
  reaper.InsertMedia(write_file .. ".wav", 3)
  reaper.Undo_EndBlock2(0, "Render nnsvs item as new take", -1)
else
  reaper.ShowConsoleMsg("Failed to read wav file. You may have failed to build the NNSVS environment.")
end
