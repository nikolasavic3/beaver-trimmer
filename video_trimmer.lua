--[[
 Video Trimmer Extension for VLC
 Version: 2.5
 
 Features:
 - Set start/end times manually or capture from playback
 - Fine-tune times with increment/decrement buttons
 - Instant trim execution when clicking folder button
 - Smart filename pattern detection with regex (YYYYMMDDHHMMSS support)
 - Adds trim start time to original timestamp in filename
 - 5 PREDEFINED customizable folder buttons (edit FOLDER_CONFIG below)
 - History display showing all completed trims with full paths
 - Navigate to next video after processing (with option to delete original)
 
 CUSTOMIZE YOUR FOLDERS:
 Edit the FOLDER_CONFIG table below to set your folder names
--]]

-- ═══════════════════════════════════════════════════════════════
-- 📁 CUSTOMIZE YOUR FOLDERS HERE
-- ═══════════════════════════════════════════════════════════════
local FOLDER_CONFIG = {
    {name = "(current)", path = ""},           -- Current folder (don't change this)
    {name = "clips", path = "clips"},          -- Subfolder 1
    {name = "trimmed", path = "trimmed"},      -- Subfolder 2
    {name = "processed", path = "processed"},  -- Subfolder 3
    {name = "archive", path = "archive"}       -- Subfolder 4
}
-- ═══════════════════════════════════════════════════════════════

-- Global variables
local dlg = nil
local trim_history = {}
local current_video_path = ""
local current_video_dir = ""
local selected_output_dir = ""
local ffmpeg_path = "ffmpeg"

-- Text input widgets
local start_time_input = nil
local end_time_input = nil
local current_time_label = nil
local status_label = nil
local history_html = nil
local smart_naming_checkbox = nil
local regex_pattern_input = nil
local regex_preview_label = nil
local output_dir_label = nil

-- Improved regex patterns for different timestamp formats
local default_regex = "(%d%d%d%d%d%d%d%d)_?(%d%d%d%d%d%d)"  -- YYYYMMDD_HHMMSS

-- Extension descriptor
function descriptor()
    return {
        title = "Video Trimmer",
        version = "2.5",
        author = "VLC User",
        capabilities = {"input-listener"}
    }
end

-- Helper function: Check if path is Windows-style
function is_windows_path(path)
    return path:match("^%a:") ~= nil or path:match("\\") ~= nil
end

-- Helper function: Get path separator based on OS
function get_path_separator(path)
    if is_windows_path(path) then
        return "\\"
    else
        return "/"
    end
end

-- Helper function: Normalize path separators
function normalize_path(path)
    if is_windows_path(path) then
        return path:gsub("/", "\\")
    else
        return path:gsub("\\", "/")
    end
end

-- Helper function: Join path components
function join_path(dir, filename)
    local sep = get_path_separator(dir)
    dir = dir:gsub("[/\\]+$", "")
    return dir .. sep .. filename
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

-- Helper function: Parse timestamp from filename
function parse_timestamp_from_filename(filename, regex)
    local date_part, time_part = filename:match(regex)
    
    if date_part and time_part then
        return date_part, time_part
    end
    
    local just_time = filename:match("(%d%d%d%d%d%d)")
    if just_time then
        return nil, just_time
    end
    
    return nil, nil
end

-- Helper function: Add seconds to timestamp
function add_seconds_to_timestamp(date_part, time_part, seconds_to_add)
    local hours = tonumber(time_part:sub(1, 2))
    local minutes = tonumber(time_part:sub(3, 4))
    local seconds = tonumber(time_part:sub(5, 6))
    
    local total_seconds = hours * 3600 + minutes * 60 + seconds
    total_seconds = total_seconds + seconds_to_add
    
    local days_to_add = 0
    if total_seconds >= 86400 then
        days_to_add = math.floor(total_seconds / 86400)
        total_seconds = total_seconds % 86400
    elseif total_seconds < 0 then
        days_to_add = -1
        total_seconds = total_seconds + 86400
    end
    
    local new_hours = math.floor(total_seconds / 3600)
    local new_minutes = math.floor((total_seconds % 3600) / 60)
    local new_seconds = math.floor(total_seconds % 60)
    
    local new_time_part = string.format("%02d%02d%02d", new_hours, new_minutes, new_seconds)
    
    local new_date_part = date_part
    if date_part and days_to_add ~= 0 then
        local year = tonumber(date_part:sub(1, 4))
        local month = tonumber(date_part:sub(5, 6))
        local day = tonumber(date_part:sub(7, 8))
        
        day = day + days_to_add
        
        local days_in_month = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}
        
        if (year % 4 == 0 and year % 100 ~= 0) or (year % 400 == 0) then
            days_in_month[2] = 29
        end
        
        while day > days_in_month[month] do
            day = day - days_in_month[month]
            month = month + 1
            if month > 12 then
                month = 1
                year = year + 1
            end
        end
        
        while day < 1 do
            month = month - 1
            if month < 1 then
                month = 12
                year = year - 1
            end
            day = day + days_in_month[month]
        end
        
        new_date_part = string.format("%04d%02d%02d", year, month, day)
    end
    
    return new_date_part, new_time_part
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
        if uri then
            local path = uri:gsub("^file:///", "/")
            path = path:gsub("^file://", "")
            path = path:gsub("%%(%x%x)", function(hex)
                return string.char(tonumber(hex, 16))
            end)
            return path
        end
    end
    return ""
end

-- Helper function: Extract directory from full path
function get_directory_from_path(filepath)
    local dir = filepath:match("^(.-)[^\\/]+$")
    if dir and dir ~= "" then
        return dir:gsub("[/\\]+$", "")
    end
    return ""
end

-- Helper function: Extract filename from full path
function get_filename_from_path(filepath)
    return filepath:match("([^\\/]+)$") or filepath
end

-- Helper function: Parse filename components with pattern matching
function parse_filename(filepath, regex)
    local filename = get_filename_from_path(filepath)
    local base_name, ext = filename:match("^(.-)%.([^%.]+)$")
    
    if not base_name then
        return nil, nil, nil, nil, nil, nil
    end
    
    local date_part, time_part = parse_timestamp_from_filename(base_name, regex)
    local name_without_timestamp = base_name
    
    if time_part then
        if date_part then
            name_without_timestamp = base_name:gsub(date_part .. "_?" .. time_part, "")
        else
            name_without_timestamp = base_name:gsub(time_part, "")
        end
        name_without_timestamp = name_without_timestamp:gsub("[_%-]+$", "")
    end
    
    return filename, base_name, name_without_timestamp, date_part, time_part, ext
end

-- Helper function: Generate smart filename
function generate_smart_filename(filepath, start_seconds, use_smart_naming, regex, output_dir)
    local filename, base_name, name_without_timestamp, date_part, time_part, ext = parse_filename(filepath, regex)
    
    if not filename then
        return join_path(output_dir, get_filename_from_path(filepath):gsub("%.([^%.]+)$", "_trim.%1"))
    end
    
    local new_filename
    
    if use_smart_naming and time_part then
        local new_date_part, new_time_part = add_seconds_to_timestamp(date_part, time_part, start_seconds)
        
        if new_date_part then
            new_filename = name_without_timestamp .. new_date_part .. "_" .. new_time_part .. "." .. ext
        else
            new_filename = name_without_timestamp .. new_time_part .. "." .. ext
        end
        
        new_filename = new_filename:gsub("__+", "_")
        new_filename = new_filename:gsub("^_", "")
    else
        new_filename = base_name .. "_trim." .. ext
    end
    
    return join_path(output_dir, new_filename)
end

-- Helper function: Generate preview of how filename will be renamed
function generate_filename_preview()
    if not regex_preview_label then return end
    
    if current_video_path == "" then
        regex_preview_label:set_text("Preview: (no video loaded)")
        return
    end
    
    local start_time = start_time_input:get_text()
    if not validate_time(start_time) then
        regex_preview_label:set_text("Preview: (invalid start time)")
        return
    end
    
    local start_sec = time_to_seconds(start_time)
    local regex = regex_pattern_input:get_text()
    local use_smart = smart_naming_checkbox:get_checked()
    local output_dir = selected_output_dir
    
    local output_file = generate_smart_filename(current_video_path, start_sec, use_smart, regex, output_dir)
    local filename = get_filename_from_path(output_file)
    
    if output_dir ~= current_video_dir then
        local relative = output_dir:match("([^\\/]+)$")
        regex_preview_label:set_text("Preview: " .. relative .. get_path_separator(output_dir) .. filename)
    else
        regex_preview_label:set_text("Preview: " .. filename)
    end
end

-- Helper function: Update history display
function update_history_display()
    if not history_html then return end
    
    local html = "<div style='font-family: monospace; font-size: 9px;'>"
    html = html .. "<b>TRIM HISTORY:</b><br>"
    
    if #trim_history == 0 then
        html = html .. "<i>No trims completed yet</i><br>"
    else
        for i = #trim_history, 1, -1 do
            local trim = trim_history[i]
            html = html .. string.format("%d. %s → %s<br>", 
                #trim_history - i + 1, trim.start_time, trim.end_time)
            html = html .. string.format("   📁 %s<br>", trim.output_file)
            if trim.status == "Completed" then
                html = html .. "   ✓ Success<br>"
            else
                html = html .. "   ✗ Failed<br>"
            end
        end
    end
    
    html = html .. "</div>"
    history_html:set_text(html)
end

-- Callback: Execute trim and save to directory
function execute_trim_to_directory(dir_path)
    selected_output_dir = dir_path
    
    if output_dir_label then
        if dir_path == current_video_dir then
            output_dir_label:set_text("Last saved to: (current folder)")
        else
            local dir_name = dir_path:match("([^\\/]+)$")
            output_dir_label:set_text("Last saved to: " .. dir_name .. " ✓")
        end
    end
    
    generate_filename_preview()
    
    local start_time = start_time_input:get_text()
    local end_time = end_time_input:get_text()
    
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
    
    current_video_path = get_video_path()
    if current_video_path == "" then
        update_status("ERROR: No video loaded")
        return
    end
    
    update_status("Processing trim...")
    
    local use_smart_naming = smart_naming_checkbox:get_checked()
    local regex = regex_pattern_input:get_text()
    
    local output_file = generate_smart_filename(current_video_path, start_sec, use_smart_naming, regex, dir_path)
    
    local duration = end_sec - start_sec
    local cmd = string.format('%s -i "%s" -ss %.3f -t %.3f -c copy "%s"',
        ffmpeg_path,
        current_video_path,
        start_sec,
        duration,
        output_file)
    
    local result = os.execute(cmd)
    
    local history_entry = {
        start_time = start_time,
        end_time = end_time,
        start_sec = start_sec,
        end_sec = end_sec,
        output_file = output_file,
        status = (result == 0 or result == true) and "Completed" or "Failed"
    }
    
    table.insert(trim_history, history_entry)
    
    if history_entry.status == "Completed" then
        update_status("✓ Trim completed: " .. get_filename_from_path(output_file))
    else
        update_status("✗ Trim failed - check FFmpeg installation")
    end
    
    update_history_display()
    
    start_time_input:set_text("00:00:00.000")
    end_time_input:set_text("00:00:00.000")
    generate_filename_preview()
end

-- Callback: Adjust time by increment
function adjust_time(input_widget, increment_seconds)
    local time_str = input_widget:get_text()
    if not validate_time(time_str) then
        update_status("ERROR: Invalid time format")
        return
    end
    
    local seconds = time_to_seconds(time_str)
    seconds = math.max(0, seconds + increment_seconds)
    
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    local secs = seconds % 60
    
    local new_time = string.format("%02d:%02d:%06.3f", hours, minutes, secs)
    input_widget:set_text(new_time)
    generate_filename_preview()
end

function start_time_up() adjust_time(start_time_input, 1) end
function start_time_down() adjust_time(start_time_input, -1) end
function start_time_up_fast() adjust_time(start_time_input, 10) end
function start_time_down_fast() adjust_time(start_time_input, -10) end
function end_time_up() adjust_time(end_time_input, 1) end
function end_time_down() adjust_time(end_time_input, -1) end
function end_time_up_fast() adjust_time(end_time_input, 10) end
function end_time_down_fast() adjust_time(end_time_input, -10) end

function capture_start_time()
    local time = get_current_time()
    local time_str = microseconds_to_time(time)
    start_time_input:set_text(time_str)
    update_status("Start time set to: " .. time_str)
    generate_filename_preview()
end

function capture_end_time()
    local time = get_current_time()
    local time_str = microseconds_to_time(time)
    end_time_input:set_text(time_str)
    update_status("End time set to: " .. time_str)
end

function play_next_video()
    local playlist = vlc.playlist.get("playlist")
    if playlist and playlist.children then
        vlc.playlist.next()
        update_status("Playing next video...")
        
        local start_time = os.clock()
        while os.clock() - start_time < 0.5 do end
        
        current_video_path = get_video_path()
        current_video_dir = get_directory_from_path(current_video_path)
        selected_output_dir = current_video_dir
        
        trim_history = {}
        update_history_display()
        generate_filename_preview()
        
        update_status("New video loaded. Please reopen extension to refresh.")
    else
        update_status("No more videos in playlist")
    end
end

function delete_and_play_next()
    if current_video_path ~= "" and #trim_history > 0 then
        local success, err = os.remove(current_video_path)
        if success then
            update_status("Original video deleted. Loading next...")
        else
            update_status("Failed to delete original: " .. tostring(err))
        end
    else
        update_status("Nothing to delete (no trims completed)")
    end
    play_next_video()
end

function keep_and_play_next()
    update_status("Original video kept. Loading next...")
    play_next_video()
end

function update_status(message)
    if status_label then
        status_label:set_text(message)
    end
end

function update_current_time_display()
    if current_time_label and vlc.input.is_playing() then
        local time = get_current_time()
        local time_str = microseconds_to_time(time)
        current_time_label:set_text("Current: " .. time_str)
    end
end

function smart_naming_changed()
    generate_filename_preview()
end

function regex_pattern_changed()
    generate_filename_preview()
end

-- Predefined callback functions for each folder button
function save_to_folder1()
    local folder_path = FOLDER_CONFIG[1].path
    if folder_path == "" then
        execute_trim_to_directory(current_video_dir)
    else
        execute_trim_to_directory(join_path(current_video_dir, folder_path))
    end
end

function save_to_folder2()
    local folder_path = FOLDER_CONFIG[2].path
    if folder_path == "" then
        execute_trim_to_directory(current_video_dir)
    else
        execute_trim_to_directory(join_path(current_video_dir, folder_path))
    end
end

function save_to_folder3()
    local folder_path = FOLDER_CONFIG[3].path
    if folder_path == "" then
        execute_trim_to_directory(current_video_dir)
    else
        execute_trim_to_directory(join_path(current_video_dir, folder_path))
    end
end

function save_to_folder4()
    local folder_path = FOLDER_CONFIG[4].path
    if folder_path == "" then
        execute_trim_to_directory(current_video_dir)
    else
        execute_trim_to_directory(join_path(current_video_dir, folder_path))
    end
end

function save_to_folder5()
    local folder_path = FOLDER_CONFIG[5].path
    if folder_path == "" then
        execute_trim_to_directory(current_video_dir)
    else
        execute_trim_to_directory(join_path(current_video_dir, folder_path))
    end
end

function activate()
    current_video_path = get_video_path()
    current_video_dir = get_directory_from_path(current_video_path)
    selected_output_dir = current_video_dir
    
    dlg = vlc.dialog("Video Trimmer v2.5")
    
    dlg:add_label("<b>Current Playback Time:</b>", 1, 1, 2, 1)
    current_time_label = dlg:add_label("Current: 00:00:00.000", 3, 1, 2, 1)
    
    dlg:add_label("Start Time:", 1, 2, 1, 1)
    start_time_input = dlg:add_text_input("00:00:00.000", 2, 2, 1, 1)
    dlg:add_button("−10s", start_time_down_fast, 3, 2, 1, 1)
    dlg:add_button("−1s", start_time_down, 4, 2, 1, 1)
    dlg:add_button("+1s", start_time_up, 5, 2, 1, 1)
    dlg:add_button("+10s", start_time_up_fast, 6, 2, 1, 1)
    dlg:add_button("⏺ Capture", capture_start_time, 7, 2, 1, 1)
    
    dlg:add_label("End Time:", 1, 3, 1, 1)
    end_time_input = dlg:add_text_input("00:00:00.000", 2, 3, 1, 1)
    dlg:add_button("−10s", end_time_down_fast, 3, 3, 1, 1)
    dlg:add_button("−1s", end_time_down, 4, 3, 1, 1)
    dlg:add_button("+1s", end_time_up, 5, 3, 1, 1)
    dlg:add_button("+10s", end_time_up_fast, 6, 3, 1, 1)
    dlg:add_button("⏺ Capture", capture_end_time, 7, 3, 1, 1)
    
    dlg:add_label("<b>Trim & Save to Directory (click button to execute):</b>", 1, 4, 7, 1)
    
    -- PREDEFINED BUTTONS - No loops, no closures, just explicit buttons
    dlg:add_button("📁 " .. FOLDER_CONFIG[1].name, save_to_folder1, 1, 5, 1, 1)
    dlg:add_button("📁 " .. FOLDER_CONFIG[2].name, save_to_folder2, 2, 5, 1, 1)
    dlg:add_button("📁 " .. FOLDER_CONFIG[3].name, save_to_folder3, 3, 5, 1, 1)
    dlg:add_button("📁 " .. FOLDER_CONFIG[4].name, save_to_folder4, 4, 5, 1, 1)
    dlg:add_button("📁 " .. FOLDER_CONFIG[5].name, save_to_folder5, 5, 5, 1, 1)
    
    output_dir_label = dlg:add_label("Last saved to: (none)", 1, 6, 7, 1)
    
    dlg:add_label("<b>Filename Options:</b>", 1, 7, 7, 1)
    smart_naming_checkbox = dlg:add_check_box("Smart naming (add time to original timestamp)", true, 1, 8, 5, 1)
    
    dlg:add_label("Regex Pattern:", 1, 9, 1, 1)
    regex_pattern_input = dlg:add_text_input(default_regex, 2, 9, 5, 1)
    
    dlg:add_label("Output Name:", 1, 10, 1, 1)
    regex_preview_label = dlg:add_label("Preview: (no video loaded)", 2, 10, 5, 1)
    
    dlg:add_label("<b>Trim History:</b>", 1, 11, 7, 1)
    history_html = dlg:add_html("", 1, 12, 7, 5)
    
    dlg:add_label("<b>Status:</b>", 1, 17, 1, 1)
    status_label = dlg:add_label("Ready", 2, 17, 6, 1)
    
    dlg:add_button("🗑➡ Delete Original & Play Next", delete_and_play_next, 1, 18, 3, 1)
    dlg:add_button("➡ Keep Original & Play Next", keep_and_play_next, 4, 18, 3, 1)
    
    update_history_display()
    if current_video_path ~= "" then
        update_status("Ready. Set times and click a folder button to trim & save.")
    else
        update_status("Ready. Load a video and set trim points.")
    end
    generate_filename_preview()
end

function deactivate()
    if dlg then
        dlg:delete()
        dlg = nil
    end
end

function close()
    vlc.deactivate()
end

function input_changed()
    current_video_path = get_video_path()
    current_video_dir = get_directory_from_path(current_video_path)
    
    if current_video_path ~= "" then
        update_status("Video loaded: " .. get_filename_from_path(current_video_path))
    end
    update_current_time_display()
end

function meta_changed()
    update_current_time_display()
end