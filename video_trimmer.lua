--[[
 Video Trimmer Extension for VLC
 Version: 2.3
 
 Features:
 - Set start/end times manually or capture from playback
 - Fine-tune times with increment/decrement buttons
 - Instant trim execution when clicking folder button
 - Smart filename pattern detection with regex (keeps timestamps in filename)
 - Dynamic buttons for subdirectory selection (max 5)
 - History display showing all completed trims with full paths
 - Navigate to next video after processing (with option to delete original)
--]]

-- Global variables
local dlg = nil
local trim_history = {}  -- Changed from queue to history
local current_video_path = ""
local current_video_dir = ""
local selected_output_dir = ""  -- Tracks selected output directory
local ffmpeg_path = "ffmpeg" -- Change this if ffmpeg is not in PATH

-- Text input widgets
local start_time_input = nil
local end_time_input = nil
local current_time_label = nil
local status_label = nil
local history_html = nil  -- Changed from trim_list_html
local smart_naming_checkbox = nil
local regex_pattern_input = nil
local regex_preview_label = nil
local output_dir_label = nil  -- Shows currently selected directory

-- Default regex pattern to match timestamp patterns in filename
-- Matches: HHMMSS, HH-MM-SS, HH_MM_SS, YYYYMMDD_HHMMSS, etc.
local default_regex = "(%d%d%d%d%d%d)(%D?)" -- Matches 6 consecutive digits (HHMMSS)

-- Extension descriptor
function descriptor()
    return {
        title = "Video Trimmer",
        version = "2.3",
        author = "VLC User",
        capabilities = {"input-listener"}
    }
end

-- Helper function: Check if path is Windows-style
function is_windows_path(path)
    -- Check for drive letter (C:, D:, etc.) or backslashes
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
    -- Remove trailing separator from dir if present
    dir = dir:gsub("[/\\]+$", "")
    return dir .. sep .. filename
end

-- Helper function: Get subdirectories of a directory (max 5)
function get_subdirectories(dir)
    local subdirs = {}
    
    if not dir or dir == "" then
        return subdirs
    end
    
    -- Normalize the path
    dir = normalize_path(dir)
    local sep = get_path_separator(dir)
    
    -- Build command based on OS
    local cmd
    if is_windows_path(dir) then
        -- Windows: use dir command
        cmd = 'dir "' .. dir .. '" /b /ad 2>nul'
    else
        -- Linux/Mac: use find command
        cmd = 'find "' .. dir .. '" -mindepth 1 -maxdepth 1 -type d 2>/dev/null'
    end
    
    -- Execute command and parse results
    local handle = io.popen(cmd)
    if handle then
        local count = 0
        for line in handle:lines() do
            if count >= 5 then break end  -- Limit to 5 subdirectories
            
            line = line:gsub("^%s+", ""):gsub("%s+$", "")  -- Trim whitespace
            if line ~= "" then
                if is_windows_path(dir) then
                    -- Windows returns just the directory name
                    table.insert(subdirs, line)
                    count = count + 1
                else
                    -- Linux returns full path, extract just the directory name
                    local dirname = line:match("([^/]+)$")
                    if dirname then
                        table.insert(subdirs, dirname)
                        count = count + 1
                    end
                end
            end
        end
        handle:close()
    end
    
    return subdirs
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

-- Helper function: Convert seconds to HHMMSS format (for filename)
function seconds_to_hhmmss(seconds)
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    local secs = math.floor(seconds % 60)
    return string.format("%02d%02d%02d", hours, minutes, secs)
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

-- Helper function: Extract directory from full path
function get_directory_from_path(filepath)
    local sep = get_path_separator(filepath)
    local dir = filepath:match("^(.-)[^\\/]+$")
    if dir and dir ~= "" then
        return dir:gsub("[/\\]+$", "")  -- Remove trailing separator
    end
    return ""
end

-- Helper function: Extract filename from full path
function get_filename_from_path(filepath)
    return filepath:match("([^\\/]+)$") or filepath
end

-- Helper function: Extract filename components with pattern matching
function parse_filename(filepath, regex)
    local filename = get_filename_from_path(filepath)
    local base_name, ext = filename:match("^(.-)%.([^%.]+)$")
    
    if not base_name then
        return nil, nil, nil, nil, nil
    end
    
    -- Try to match the pattern in filename
    local matched_time, separator = base_name:match(regex)
    local name_without_time = base_name
    
    if matched_time then
        -- Found a time pattern - extract the base name without the time
        name_without_time = base_name:gsub(regex, "")
        -- Remove trailing separators/underscores
        name_without_time = name_without_time:gsub("[_%-]$", "")
    end
    
    return filename, base_name, name_without_time, matched_time, ext
end

-- Helper function: Generate smart filename
function generate_smart_filename(filepath, start_seconds, use_smart_naming, regex, output_dir)
    local filename, base_name, name_without_time, matched_time, ext = parse_filename(filepath, regex)
    
    if not filename then
        -- Fallback if parsing fails
        return join_path(output_dir, get_filename_from_path(filepath):gsub("%.([^%.]+)$", "_trim.%1"))
    end
    
    local new_filename
    
    if use_smart_naming and matched_time then
        -- Smart naming: replace original time with new time based on trim start
        local new_time = seconds_to_hhmmss(start_seconds)
        new_filename = name_without_time .. new_time .. "." .. ext
    else
        -- Default naming: append _trim suffix
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
    
    -- Show the subdirectory if not current
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
        -- Show most recent first (reverse order)
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

-- Callback: Execute trim and save to directory (INSTANT EXECUTION)
function execute_trim_to_directory(dir_path)
    -- First, set the selected directory
    selected_output_dir = dir_path
    
    -- Update the label to show selected directory
    if output_dir_label then
        if dir_path == current_video_dir then
            output_dir_label:set_text("Last saved to: (current folder)")
        else
            local dir_name = dir_path:match("([^\\/]+)$")
            output_dir_label:set_text("Last saved to: " .. dir_name .. " ✓")
        end
    end
    
    -- Update preview
    generate_filename_preview()
    
    -- Validate times
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
    
    -- Get current video path
    current_video_path = get_video_path()
    if current_video_path == "" then
        update_status("ERROR: No video loaded")
        return
    end
    
    -- Execute trim immediately
    update_status("Processing trim...")
    
    local use_smart_naming = smart_naming_checkbox:get_checked()
    local regex = regex_pattern_input:get_text()
    
    local output_file = generate_smart_filename(current_video_path, start_sec, use_smart_naming, regex, dir_path)
    
    -- Build FFmpeg command
    local duration = end_sec - start_sec
    local cmd = string.format('%s -i "%s" -ss %.3f -t %.3f -c copy "%s"',
        ffmpeg_path,
        current_video_path,
        start_sec,
        duration,
        output_file)
    
    -- Execute command
    local result = os.execute(cmd)
    
    -- Create history entry
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
    
    -- Update history display
    update_history_display()
    
    -- Clear inputs for next trim
    start_time_input:set_text("00:00:00.000")
    end_time_input:set_text("00:00:00.000")
    generate_filename_preview()
end

-- Callback: Adjust time by increment (in seconds)
function adjust_time(input_widget, increment_seconds)
    local time_str = input_widget:get_text()
    if not validate_time(time_str) then
        update_status("ERROR: Invalid time format")
        return
    end
    
    local seconds = time_to_seconds(time_str)
    seconds = math.max(0, seconds + increment_seconds) -- Don't go below 0
    
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    local secs = seconds % 60
    
    local new_time = string.format("%02d:%02d:%06.3f", hours, minutes, secs)
    input_widget:set_text(new_time)
    
    -- Update preview if smart naming is enabled
    generate_filename_preview()
end

-- Callback: Increment/decrement start time
function start_time_up()
    adjust_time(start_time_input, 1)
end

function start_time_down()
    adjust_time(start_time_input, -1)
end

function start_time_up_fast()
    adjust_time(start_time_input, 10)
end

function start_time_down_fast()
    adjust_time(start_time_input, -10)
end

-- Callback: Increment/decrement end time
function end_time_up()
    adjust_time(end_time_input, 1)
end

function end_time_down()
    adjust_time(end_time_input, -1)
end

function end_time_up_fast()
    adjust_time(end_time_input, 10)
end

function end_time_down_fast()
    adjust_time(end_time_input, -10)
end

-- Callback: Capture start time
function capture_start_time()
    local time = get_current_time()
    local time_str = microseconds_to_time(time)
    start_time_input:set_text(time_str)
    update_status("Start time set to: " .. time_str)
    generate_filename_preview()
end

-- Callback: Capture end time
function capture_end_time()
    local time = get_current_time()
    local time_str = microseconds_to_time(time)
    end_time_input:set_text(time_str)
    update_status("End time set to: " .. time_str)
end

-- Helper function: Play next video in playlist
function play_next_video()
    -- Check if there are more items in playlist
    local playlist = vlc.playlist.get("playlist")
    if playlist and playlist.children then
        -- Try to play next
        vlc.playlist.next()
        update_status("Playing next video...")
        
        -- Small delay to let VLC switch videos
        local start_time = os.clock()
        while os.clock() - start_time < 0.5 do
            -- Brief pause
        end
        
        -- Update current video path and directory
        current_video_path = get_video_path()
        current_video_dir = get_directory_from_path(current_video_path)
        selected_output_dir = current_video_dir  -- Reset to current directory
        
        -- Clear history for new video
        trim_history = {}
        update_history_display()
        generate_filename_preview()
        
        update_status("New video loaded. Please reopen extension to refresh directory buttons.")
    else
        update_status("No more videos in playlist")
    end
end

-- Callback: Delete original and play next
function delete_and_play_next()
    if current_video_path ~= "" and #trim_history > 0 then
        -- Delete the original file
        local success, err = os.remove(current_video_path)
        if success then
            update_status("Original video deleted. Loading next...")
        else
            update_status("Failed to delete original: " .. tostring(err))
        end
    else
        update_status("Nothing to delete (no trims completed)")
    end
    
    -- Play next video
    play_next_video()
end

-- Callback: Keep original and play next
function keep_and_play_next()
    update_status("Original video kept. Loading next...")
    play_next_video()
end

-- Update status message
function update_status(message)
    if status_label then
        status_label:set_text(message)
    end
end

-- Update current time display (called periodically)
function update_current_time_display()
    if current_time_label and vlc.input.is_playing() then
        local time = get_current_time()
        local time_str = microseconds_to_time(time)
        current_time_label:set_text("Current: " .. time_str)
    end
end

-- Callback: Smart naming checkbox changed
function smart_naming_changed()
    generate_filename_preview()
end

-- Callback: Regex pattern changed
function regex_pattern_changed()
    generate_filename_preview()
end

-- Called when extension is activated
function activate()
    -- Get initial video info
    current_video_path = get_video_path()
    current_video_dir = get_directory_from_path(current_video_path)
    selected_output_dir = current_video_dir  -- Default to current directory
    
    -- Get subdirectories
    local subdirs = get_subdirectories(current_video_dir)
    
    -- Create dialog
    dlg = vlc.dialog("Video Trimmer v2.3")
    
    -- Row 1: Current time display
    dlg:add_label("<b>Current Playback Time:</b>", 1, 1, 2, 1)
    current_time_label = dlg:add_label("Current: 00:00:00.000", 3, 1, 2, 1)
    
    -- Row 2: Start time with adjustment buttons
    dlg:add_label("Start Time:", 1, 2, 1, 1)
    start_time_input = dlg:add_text_input("00:00:00.000", 2, 2, 1, 1)
    dlg:add_button("−10s", start_time_down_fast, 3, 2, 1, 1)
    dlg:add_button("−1s", start_time_down, 4, 2, 1, 1)
    dlg:add_button("+1s", start_time_up, 5, 2, 1, 1)
    dlg:add_button("+10s", start_time_up_fast, 6, 2, 1, 1)
    dlg:add_button("⏺ Capture", capture_start_time, 7, 2, 1, 1)
    
    -- Row 3: End time with adjustment buttons
    dlg:add_label("End Time:", 1, 3, 1, 1)
    end_time_input = dlg:add_text_input("00:00:00.000", 2, 3, 1, 1)
    dlg:add_button("−10s", end_time_down_fast, 3, 3, 1, 1)
    dlg:add_button("−1s", end_time_down, 4, 3, 1, 1)
    dlg:add_button("+1s", end_time_up, 5, 3, 1, 1)
    dlg:add_button("+10s", end_time_up_fast, 6, 3, 1, 1)
    dlg:add_button("⏺ Capture", capture_end_time, 7, 3, 1, 1)
    
    -- Row 4: Output directory buttons header
    dlg:add_label("<b>Trim & Save to Directory (click button to execute):</b>", 1, 4, 7, 1)
    
    -- Row 5: Directory selection buttons (dynamically created, max 5 subdirs)
    -- KEEPING DYNAMIC BUTTON DISPLAY EXACTLY AS BEFORE - DO NOT TOUCH!
    -- First button: current folder
    local col = 1
    dlg:add_button("📁 (current)", function() execute_trim_to_directory(current_video_dir) end, col, 5, 1, 1)
    col = col + 1
    
    -- Additional buttons for subdirectories (max 5)
    for i, subdir in ipairs(subdirs) do
        if i <= 4 then  -- Max 4 subdirs + 1 current = 5 total buttons
            local subdir_path = join_path(current_video_dir, subdir)
            dlg:add_button("📁 " .. subdir, function() execute_trim_to_directory(subdir_path) end, col, 5, 1, 1)
            col = col + 1
        end
    end
    
    -- Row 6: Selected directory indicator
    output_dir_label = dlg:add_label("Last saved to: (none)", 1, 6, 7, 1)
    
    -- Row 7: Filename options header
    dlg:add_label("<b>Filename Options:</b>", 1, 7, 7, 1)
    
    -- Row 8: Smart naming checkbox
    smart_naming_checkbox = dlg:add_check_box("Smart naming (keep time pattern)", true, 1, 8, 3, 1)
    
    -- Row 9: Regex pattern
    dlg:add_label("Regex Pattern:", 1, 9, 1, 1)
    regex_pattern_input = dlg:add_text_input(default_regex, 2, 9, 5, 1)
    
    -- Row 10: Preview
    dlg:add_label("Output Name:", 1, 10, 1, 1)
    regex_preview_label = dlg:add_label("Preview: (no video loaded)", 2, 10, 5, 1)
    
    -- Row 11-15: History display
    dlg:add_label("<b>Trim History:</b>", 1, 11, 7, 1)
    history_html = dlg:add_html("", 1, 12, 7, 5)
    
    -- Row 17: Status
    dlg:add_label("<b>Status:</b>", 1, 17, 1, 1)
    status_label = dlg:add_label("Ready", 2, 17, 6, 1)
    
    -- Row 18: Navigation buttons
    dlg:add_button("🗑➡ Delete Original & Play Next", delete_and_play_next, 1, 18, 3, 1)
    dlg:add_button("➡ Keep Original & Play Next", keep_and_play_next, 4, 18, 3, 1)
    
    -- Initialize displays
    update_history_display()
    if current_video_path ~= "" then
        update_status("Ready. Set times and click a folder button to trim & save.")
    else
        update_status("Ready. Load a video and set trim points.")
    end
    generate_filename_preview()
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
    current_video_dir = get_directory_from_path(current_video_path)
    
    if current_video_path ~= "" then
        update_status("Video loaded: " .. get_filename_from_path(current_video_path))
        -- Note: Directory buttons don't update dynamically
        -- User should reopen extension for new video
    end
    update_current_time_display()
end

-- Called during playback (to update current time)
function meta_changed()
    update_current_time_display()
end