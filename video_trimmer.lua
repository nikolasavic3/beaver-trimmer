--[[
 Video Trimmer Extension for VLC
 Version: 1.0
 
 Features:
 - Set start/end times manually or capture from playback
 - Queue multiple trim operations
 - Execute FFmpeg to create trimmed video copies
 - Display list of queued/completed trims
 - Option to delete original or keep it on exit
--]]

-- Global variables
local dlg = nil
local trim_queue = {}
local completed_trims = {}
local current_video_path = ""
local ffmpeg_path = "ffmpeg" -- Change this if ffmpeg is not in PATH

-- Text input widgets
local start_time_input = nil
local end_time_input = nil
local current_time_label = nil
local status_label = nil
local trim_list_html = nil
local delete_original_checkbox = nil

-- Extension descriptor
function descriptor()
    return {
        title = "Video Trimmer",
        version = "1.0",
        author = "VLC User",
        capabilities = {"input-listener"}
    }
end

-- Helper function: Convert microseconds to HH:MM:SS format
function microseconds_to_time(microseconds)
    local total_seconds = microseconds / 1000000
    local hours = math.floor(total_seconds / 3600)
    local minutes = math.floor((total_seconds % 3600) / 60)
    local seconds = total_seconds % 60
    return string.format("%02d:%02d:%06.3f", hours, minutes, seconds)
end

-- Helper function: Convert HH:MM:SS to seconds (for FFmpeg)
function time_to_seconds(time_str)
    local hours, minutes, seconds = time_str:match("(%d+):(%d+):([%d.]+)")
    if not hours then return 0 end
    return tonumber(hours) * 3600 + tonumber(minutes) * 60 + tonumber(seconds)
end

-- Helper function: Validate time format
function validate_time(time_str)
    return time_str:match("^%d+:%d+:[%d.]+$") ~= nil
end

-- Helper function: Get current playback time
function get_current_time()
    local input = vlc.object.input()
    if input then
        local time = vlc.var.get(input, "time")
        return time
    end
    return 0
end

-- Helper function: Get current video file path
function get_video_path()
    local item = vlc.input.item()
    if item then
        local uri = item:uri()
        -- Convert file:/// URI to regular path
        if uri then
            -- Remove file:/// prefix and decode URL encoding
            local path = uri:gsub("^file:///", "")
            path = path:gsub("^file://", "")
            path = path:gsub("%%(%x%x)", function(hex)
                return string.char(tonumber(hex, 16))
            end)
            return path
        end
    end
    return ""
end

-- Callback: Capture start time
function capture_start_time()
    local time = get_current_time()
    local time_str = microseconds_to_time(time)
    start_time_input:set_text(time_str)
    update_status("Start time set to: " .. time_str)
end

-- Callback: Capture end time
function capture_end_time()
    local time = get_current_time()
    local time_str = microseconds_to_time(time)
    end_time_input:set_text(time_str)
    update_status("End time set to: " .. time_str)
end

-- Callback: Add trim to queue
function add_to_queue()
    local start_time = start_time_input:get_text()
    local end_time = end_time_input:get_text()
    
    -- Validate times
    if not validate_time(start_time) or not validate_time(end_time) then
        update_status("ERROR: Invalid time format. Use HH:MM:SS.mmm")
        return
    end
    
    local start_sec = time_to_seconds(start_time)
    local end_sec = time_to_seconds(end_time)
    
    if start_sec >= end_sec then
        update_status("ERROR: Start time must be before end time")
        return
    end
    
    -- Get current video path
    current_video_path = get_video_path()
    if current_video_path == "" then
        update_status("ERROR: No video loaded")
        return
    end
    
    -- Add to queue
    local trim = {
        start_time = start_time,
        end_time = end_time,
        start_sec = start_sec,
        end_sec = end_sec,
        status = "Queued"
    }
    table.insert(trim_queue, trim)
    
    update_status("Added trim: " .. start_time .. " to " .. end_time)
    update_trim_list()
    
    -- Clear inputs for next trim
    start_time_input:set_text("00:00:00.000")
    end_time_input:set_text("00:00:00.000")
end

-- Callback: Execute all trims
function execute_trims()
    if #trim_queue == 0 then
        update_status("ERROR: No trims in queue")
        return
    end
    
    if current_video_path == "" then
        update_status("ERROR: No video path available")
        return
    end
    
    update_status("Processing " .. #trim_queue .. " trim(s)...")
    
    -- Get file extension and base name
    local dir, filename, ext = current_video_path:match("^(.-)([^\\/]-)%.([^%.]+)$")
    if not dir then
        dir = ""
        filename, ext = current_video_path:match("^([^\\/]-)%.([^%.]+)$")
        if not filename then
            update_status("ERROR: Could not parse filename")
            return
        end
    end
    
    -- Process each trim
    for i, trim in ipairs(trim_queue) do
        local output_file = dir .. filename .. "_trim" .. i .. "." .. ext
        
        -- Build FFmpeg command
        local duration = trim.end_sec - trim.start_sec
        local cmd = string.format('%s -i "%s" -ss %.3f -t %.3f -c copy "%s"',
            ffmpeg_path,
            current_video_path,
            trim.start_sec,
            duration,
            output_file)
        
        -- Execute command
        trim.status = "Processing..."
        update_trim_list()
        
        local result = os.execute(cmd)
        
        if result == 0 or result == true then
            trim.status = "Completed"
            trim.output_file = output_file
            table.insert(completed_trims, trim)
        else
            trim.status = "Failed"
        end
        
        update_trim_list()
    end
    
    update_status("All trims processed! Created " .. #completed_trims .. " file(s)")
end

-- Callback: Clear queue
function clear_queue()
    trim_queue = {}
    update_trim_list()
    update_status("Queue cleared")
end

-- Update status message
function update_status(message)
    if status_label then
        status_label:set_text(message)
    end
end

-- Update the trim list display
function update_trim_list()
    if not trim_list_html then return end
    
    local html = "<div style='font-family: monospace; font-size: 10px;'>"
    html = html .. "<b>QUEUED TRIMS:</b><br>"
    
    if #trim_queue == 0 then
        html = html .. "<i>No trims queued</i><br>"
    else
        for i, trim in ipairs(trim_queue) do
            html = html .. string.format("%d. %s → %s [%s]<br>",
                i, trim.start_time, trim.end_time, trim.status)
        end
    end
    
    html = html .. "<br><b>COMPLETED TRIMS:</b><br>"
    if #completed_trims == 0 then
        html = html .. "<i>No completed trims</i><br>"
    else
        for i, trim in ipairs(completed_trims) do
            html = html .. string.format("%d. %s → %s ✓<br>", 
                i, trim.start_time, trim.end_time)
        end
    end
    
    html = html .. "</div>"
    trim_list_html:set_text(html)
end

-- Update current time display (called periodically)
function update_current_time_display()
    if current_time_label and vlc.input.is_playing() then
        local time = get_current_time()
        local time_str = microseconds_to_time(time)
        current_time_label:set_text("Current: " .. time_str)
    end
end

-- Callback: Close and delete original
function close_and_delete()
    if current_video_path ~= "" and #completed_trims > 0 then
        local confirm = "Are you sure you want to delete the original video?"
        -- Note: VLC Lua doesn't have a native confirm dialog, so we just do it
        os.remove(current_video_path)
        update_status("Original video deleted")
    end
    
    -- Pause playback
    if vlc.input.is_playing() then
        vlc.playlist.pause()
    end
    
    vlc.deactivate()
end

-- Callback: Close and keep original
function close_and_keep()
    update_status("Closing - original video kept")
    
    -- Pause playback
    if vlc.input.is_playing() then
        vlc.playlist.pause()
    end
    
    vlc.deactivate()
end

-- Called when extension is activated
function activate()
    -- Create dialog
    dlg = vlc.dialog("Video Trimmer")
    
    -- Row 1: Current time display
    dlg:add_label("<b>Current Playback Time:</b>", 1, 1, 2, 1)
    current_time_label = dlg:add_label("Current: 00:00:00.000", 3, 1, 2, 1)
    
    -- Row 2: Start time
    dlg:add_label("Start Time:", 1, 2, 1, 1)
    start_time_input = dlg:add_text_input("00:00:00.000", 2, 2, 2, 1)
    dlg:add_button("⏺ Capture Start", capture_start_time, 4, 2, 1, 1)
    
    -- Row 3: End time
    dlg:add_label("End Time:", 1, 3, 1, 1)
    end_time_input = dlg:add_text_input("00:00:00.000", 2, 3, 2, 1)
    dlg:add_button("⏺ Capture End", capture_end_time, 4, 3, 1, 1)
    
    -- Row 4: Action buttons
    dlg:add_button("➕ Add to Queue", add_to_queue, 1, 4, 1, 1)
    dlg:add_button("✂ Execute All Trims", execute_trims, 2, 4, 1, 1)
    dlg:add_button("🗑 Clear Queue", clear_queue, 3, 4, 1, 1)
    
    -- Row 5-8: Trim list display
    dlg:add_label("<b>Trim Queue & Status:</b>", 1, 5, 4, 1)
    trim_list_html = dlg:add_html("", 1, 6, 4, 4)
    
    -- Row 10: Status
    dlg:add_label("<b>Status:</b>", 1, 10, 1, 1)
    status_label = dlg:add_label("Ready", 2, 10, 3, 1)
    
    -- Row 11: Close options
    dlg:add_button("🚪 Close & Delete Original", close_and_delete, 1, 11, 2, 1)
    dlg:add_button("🚪 Close & Keep Original", close_and_keep, 3, 11, 2, 1)
    
    -- Initialize displays
    update_trim_list()
    update_status("Ready. Load a video and set trim points.")
end

-- Called when extension is deactivated
function deactivate()
    if dlg then
        dlg:delete()
        dlg = nil
    end
end

-- Called when dialog is closed
function close()
    vlc.deactivate()
end

-- Called when input changes (new video loaded)
function input_changed()
    current_video_path = get_video_path()
    if current_video_path ~= "" then
        update_status("Video loaded: " .. current_video_path)
    end
    update_current_time_display()
end

-- Called during playback (to update current time)
function meta_changed()
    update_current_time_display()
end
