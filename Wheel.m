% Wheel - Controller for Running Wheels described in the link below.
% Wheel methods:
%   delete - Release connections and close GUI.
%   pause  - Release connections temporarily.
%   resume - Resume connections.
%   getLock - Get locking distance for a given tag.
%   setLock - Set locking distance for a given tag.
%   addLock - Set locking distance for a given tag, relative to current distance.
%   scheduleLock - Similar to addLock, at the scheduled time.
%   clearScheduleLock - Clear a previously scheduled lock.
%
% There is a continuous scanning process that discovers and reports connection states with the running wheels:
%     paused: The program is paused and the program closed the COM ports.
%     handshaking: The program opened the COM port and is expecting a handshake.
%     connected: An expected handshake was received from the opened COM port.
%     unavailable: The COM port could not be opened.
%     incompatible: An expected handshake was not received within 2 seconds after opening the COM port.
%     reconnecting: Re-attempting to connect to ports after the program had been paused.
%     inactive: A previously connected wheel has not reported active at regular intervals of 1 second.
%     removed: The COM port was disconnected from the computer.
%     not in sync: A previously connected wheel sent an unexpected message (either the device, the cabling or the program within are corrupted).

% 2019-04-30. Leonardo Molina
% 2022-08-09 Last modified.
classdef Wheel < handle
    properties
        debugging = false       % Print saved data to console.
        verbose = false         % Print verbose debugging messages to console.
    end
    
    properties (Constant)
        radius = 4.5            % Distance (cm) from center of wheel to running mouse.
        voltage = 3.3           % Voltage (V) of the microcontroller.
        nHallSensors = 3        % Number of hall sensors.
        temperatureInterval = 5 % Temperature saving interval (s).
        plotTrail = 30          % Length of the time window displaying temperature and distance.
    end
    
    properties (Constant, Hidden)
        tagStateTemplate = struct('distance', 0, 'lockDistance', Inf, 'scheduleLock', false, 'scheduleLockArmed', false, 'scheduleLockDistance', Inf, 'scheduleLockTime', 0, 'line', NaN, 'times', [], 'distances', [])
        colors = struct('valid', [1.00, 1.00, 1.00], 'invalid', [1.00, 0.00, 0.00]);
        trio = struct('unset', -1, 'false', 0, 'true', 1)
        lockStates = struct('locked', 0, 'unlocked', 1)
        noTag = '0000000000'        % Default tag.
        tickerInterval = 3.0        % Interval between device state checks.
        baudrate = 9600             % Baudrate of communication.
        nSync = 10                  % Size of the handshake.
    end
    
    properties (Access = private)
        % Maintain com port states.
        % name: com port name.
        % device: handle to com port device.
        % bytes: buffer data until a message is complete.
        % opened/available/compatible/greeted: actions completed on the device.
        % ticker: last time an action occurred in this device.
        % id/tag/temperature: wheel id / rfid tag / temperature last read.
        % temperatures/times: history of temperature read.
        % line: handle to temperature plot.
        ports = struct('name', {}, 'device', {}, 'bytes', {}, 'opened', {}, 'available', {}, 'compatible', {}, 'greeted', {}, 'ticker', {}, 'id', {}, 'tag', {}, 'temperature', {}, 'temperatures', {}, 'times', {}, 'line', {})
        
        rootFolder                  % C:\User\<Username>\Documents\Wheel
        tags = {}                   % List of all read tags.
        tagStates                   % Dictionary to structure to maintain handles to a line plot and its states.
        fileIds                     % Dictionary to file handles.
        tagListSelection = false    % UI selection vector.
        timerStopped = false        % Stop timer only once.
        scanning = true             % Control port scanning mechanism.
        
        ticker                      % Background timer.
        session                     % Session id.
        startTic                    % Remember start tic.
        temperatureNext             % Ticker for temperature logs.
        tickerNext                  % Ticker for port scan updates.
        visiblePorts = {}           % 
        handles                     % Handles to all GUI components.
        portProbe                   % 
    end
    
    methods
        function obj = Wheel()
            % Wheel - Controller for Running Wheels.
            
            % Initialization.
            obj.rootFolder = fullfile(getenv('USERPROFILE'), 'Documents', 'Wheel');
            if exist(obj.rootFolder, 'dir') ~= 7
                mkdir(obj.rootFolder);
            end
            obj.startTic = tic;
            obj.session = datestr(now, 'yyyymmddHHMMSS');
            obj.tickerNext = Wheel.tickerInterval;
            obj.temperatureNext = Wheel.temperatureInterval;
            obj.handles.dialogs = containers.Map();
            obj.handles.distanceLines = [];
            obj.tagStates = containers.Map();
            obj.fileIds = containers.Map();
            obj.tagListSelection = false;
            obj.portProbe = Ports();
            
            % Create GUI using a layout.
            screenSize = get(0, 'ScreenSize');
            screenSize = screenSize(3:4);
            nControlRows = 5;
            nControlColumns = 6;
            uiHeight = 22;
            padding = 10;
            panelWidth = uiHeight * 20;
            
            obj.handles.figure = uifigure('Name', mfilename('Class'), 'MenuBar', 'none', 'NumberTitle', 'off', 'ToolBar', 'none', 'CloseRequestFcn', @(~, ~)obj.onFigureClose);
            targetSize = screenSize(2) .* [0.75, 0.75];
            obj.handles.figure.Position = [(screenSize(1) - targetSize(1)) / 2, (screenSize(2) - targetSize(2)) / 2, targetSize(1), targetSize(2)];
            
            obj.handles.mainLayout = uigridlayout(obj.handles.figure);
            obj.handles.mainLayout.RowHeight = {'2x', '1x', (uiHeight + padding) * nControlRows};
            obj.handles.mainLayout.ColumnWidth = {'1x', panelWidth};
            
            obj.handles.distanceAxes = uiaxes(obj.handles.mainLayout);
            obj.handles.distanceAxes.Layout.Row = 1;
            obj.handles.distanceAxes.Layout.Column = [1, 2];
            obj.handles.temperatureAxes = uiaxes(obj.handles.mainLayout);
            obj.handles.temperatureAxes.Layout.Row = 2;
            obj.handles.temperatureAxes.Layout.Column = [1, 2];
            obj.handles.tagList = uilistbox(obj.handles.mainLayout, 'Items', {}, 'Multiselect', 'on', 'ValueChangedFcn', @(~, ~)obj.onTagListChanged, 'FontName', 'Monospaced');
            obj.handles.tagList.Layout.Row = 3;
            obj.handles.tagList.Layout.Column = 1;
            grid(obj.handles.distanceAxes, 'on');
            grid(obj.handles.temperatureAxes, 'on');
            obj.handles.distanceAxes.XTickLabel = deal('');
                    
            obj.handles.controlsPanel = uipanel(obj.handles.mainLayout);
            obj.handles.controlsPanel.Layout.Row = 3;
            obj.handles.controlsPanel.Layout.Column = 2;
            obj.handles.controlsLayout = uigridlayout(obj.handles.controlsPanel);
            obj.handles.controlsLayout.RowHeight = repmat({'1x'}, 1, nControlRows);
            obj.handles.controlsLayout.ColumnWidth = repmat({'1x'}, 1, nControlColumns);
            
            obj.handles.tagLabel = uilabel(obj.handles.controlsLayout, 'Text', 'Tag List:');
            obj.handles.tagLabel.Layout.Row = [1, 3];
            obj.handles.tagLabel.Layout.Column = [1, 2];
            obj.handles.tagEdit = uitextarea(obj.handles.controlsLayout, 'ValueChangedFcn', @(~, ~)obj.onTagEdit);
            obj.handles.tagEdit.Layout.Row = [1, 3];
            obj.handles.tagEdit.Layout.Column = [3, 6];
            
            obj.handles.distanceLabel = uilabel(obj.handles.controlsLayout, 'Text', 'Lock Distance (cm):');
            obj.handles.distanceLabel.Layout.Row = 4;
            obj.handles.distanceLabel.Layout.Column = [1, 2];
            obj.handles.distanceEdit = uitextarea(obj.handles.controlsLayout, 'ValueChangedFcn', @(~, ~)obj.onDistanceEdit);
            obj.handles.distanceEdit.Layout.Row = 4;
            obj.handles.distanceEdit.Layout.Column = 3;
            obj.handles.setLockButton = uibutton(obj.handles.controlsLayout, 'Text', 'Set', 'ButtonPushedFcn', @(~, ~)obj.onSetLock);
            obj.handles.setLockButton.Layout.Row = 4;
            obj.handles.setLockButton.Layout.Column = 4;
            obj.handles.addLockButton = uibutton(obj.handles.controlsLayout, 'Text', 'Add', 'ButtonPushedFcn', @(~, ~)obj.onAddLock);
            obj.handles.addLockButton.Layout.Row = 4;
            obj.handles.addLockButton.Layout.Column = 5;
            obj.handles.scheduleLockButton = uibutton(obj.handles.controlsLayout, 'Text', 'Schedule', 'ButtonPushedFcn', @(~, ~)obj.onScheduleLock);
            obj.handles.scheduleLockButton.Layout.Row = 4;
            obj.handles.scheduleLockButton.Layout.Column = 6;
            
            obj.handles.toggleConnectionButton = uibutton(obj.handles.controlsLayout, 'Text', 'Pause', 'ButtonPushedFcn', @(~, ~)obj.onToggleConnection);
            obj.handles.toggleConnectionButton.Layout.Row = 5;
            obj.handles.toggleConnectionButton.Layout.Column = [3, 5];
            
            obj.handles.helpButton = uibutton(obj.handles.controlsLayout, 'Text', 'Help', 'ButtonPushedFcn', @(~, ~)web('https://github.com/leomol/running-wheel'));
            obj.handles.helpButton.Layout.Row = 5;
            obj.handles.helpButton.Layout.Column = 6;
            
            xlabel(obj.handles.temperatureAxes, 'Time (s)');
            ylabel(obj.handles.temperatureAxes, 'Temperature (Celsius)');
            ylabel(obj.handles.distanceAxes, 'Distance (cm)');
            hold(obj.handles.temperatureAxes, 'all');
            hold(obj.handles.distanceAxes, 'all');
            box(obj.handles.temperatureAxes, 'on')
            box(obj.handles.distanceAxes, 'on')
            warning('OFF', 'MATLAB:legend:IgnoringExtraEntries');
            legend(obj.handles.temperatureAxes, 'on');
            legend(obj.handles.distanceAxes, 'on');
            
            % Start loop.
            obj.initializeTagState(Wheel.noTag);
            obj.ticker = timer('TimerFcn', @(~, ~)obj.onLoop, 'StopFcn', @(~, ~)obj.dispose, 'BusyMode', 'drop', 'ExecutionMode', 'fixedSpacing', 'Name', [mfilename('Class') ' - monitor'], 'Period', 100e-3);
            start(obj.ticker);
        end
        
        function delete(obj)
            % Wheel.delete()
            % Release connections and close GUI.
            
            % Request termination.
            obj.stopTimer();
        end
        
        function pause(obj)
            % Wheel.pause()
            % Release connections temporarily.
            
            obj.scanning = false;
            testPorts = {obj.ports.name};
            for p = 1:numel(testPorts)
                name = testPorts{p};
                obj.closePort(name);
                obj.ports(p).compatible = Wheel.trio.unset;
                obj.setConnectionStatus(name, 'paused');
            end
        end
        
        function resume(obj)
            % Wheel.resume()
            % Resume connections.
            
            obj.scanning = true;
            testPorts = {obj.ports.name};
            for p = 1:numel(testPorts)
                name = testPorts{p};
                obj.setConnectionStatus(name, 'reconnecting');
            end
            obj.tickerNext = 0;
        end
        
        function lockDistance = getLock(obj, tag)
            % lockDistance = Wheel.getLock(tag)
            % Get locking distance for a given tag.
            
            obj.initializeTagState(tag);
            lockDistance = obj.tagStates(tag).lockDistance;
        end
        
        function setLock(obj, tag, lockDistance, clearSchedule)
            % Wheel.setLock(tag, lockDistance)
            % Set locking distance for a given tag.
            obj.initializeTagState(tag);
            if nargin < 4
                clearSchedule = true;
            end
            if clearSchedule
                obj.clearScheduleLock(tag);
            end
            obj.setTagState(tag, 'lockDistance', lockDistance);
            obj.updateTagList();
            p = ismember({obj.ports.tag}, tag);
            if any(p)
                name = obj.ports(p).name;
                obj.updateLock(name, tag);
            end
        end
        
        function addLock(obj, tag, distance, varargin)
            % Wheel.addLock(tag, distance)
            % Set locking distance for a given tag, relative to current distance.
            
            obj.initializeTagState(tag);
            obj.setLock(tag, obj.tagStates(tag).distance + distance, varargin{:});
        end
        
        function scheduleLock(obj, tag, distance, h, m, s)
            % Wheel.scheduleLock(tag, distance, h, m, s)
            % Similar to addLock, at the scheduled time.
            
            obj.setTagState(tag, 'scheduleLock', true);
            obj.setTagState(tag, 'scheduleLockArmed', true);
            obj.setTagState(tag, 'scheduleLockDistance', distance);
            obj.setTagState(tag, 'scheduleLockTime', sum([h * 10000, m * 100, s]));
            obj.updateTagList();
        end
        
        function clearScheduleLock(obj, tag)
            % Wheel.clearScheduleLock(tag)
            % Clear a previously scheduled lock for a given tag.
            
            obj.setTagState(tag, 'scheduleLock', false);
        end
    end
    
    methods (Access = private)
        function dispose(obj)
            % Wheel.dispose()
            % Release connections and close GUI.
            
            delete(obj.handles.figure);
            delete([obj.ports.device]);
            fids = obj.fileIds.values;
            fids = cat(2, fids{:});
            for f = fids
                try
                    fclose(f);
                catch
                end
            end
        end
        
        function initializeTagState(obj, tag)
            % Wheel.initializeTagState(tag)
            % Initialize structure to maintain handles to a line plot and its states.
            
            if ~ismember(tag, obj.tags)
                obj.tags{end + 1} = tag;
                obj.tagStates(tag) = obj.tagStateTemplate;
                obj.setTagState(tag, 'line', plot(obj.handles.distanceAxes, NaN, NaN, 'Marker', 'none', 'LineStyle', '-', 'DisplayName', sprintf('Tag %s', tag)));
                obj.updateTagList();
            end
        end
        
        function setTagState(obj, tag, key, value)
            % Wheel.setTagState(tag, key, value)
            % Set value to key to an rvalue-like structure.
            
            obj.initializeTagState(tag);
            structure = obj.tagStates(tag);
            structure.(key) = value;
            obj.tagStates(tag) = structure;
        end
        
        function onFigureClose(obj)
            % Wheel.onFigureClose()
            % Capture figure closing.
            
            obj.stopTimer();
        end
        
        function onToggleConnection(obj)
            % Wheel.onToggleConnection()
            % Capture Pause/Resume button presses.
            
            if obj.scanning
                obj.handles.toggleConnectionButton.Text = 'Resume';
                obj.scanning = false;
                obj.pause();
            else
                obj.handles.toggleConnectionButton.Text = 'Pause';
                obj.scanning = true;
                obj.resume();
            end
        end
        
        function onTagListChanged(obj)
            % Wheel.onTagListChanged()
            % Capture changes to the tag text-box.
            
            obj.tagListSelection = ismember(obj.handles.tagList.Items, obj.handles.tagList.Value);
            if any(obj.tagListSelection)
                text = obj.tags(obj.tagListSelection);
            else
                text = {''};
            end
            obj.handles.tagEdit.BackgroundColor = Wheel.colors.valid;
            obj.handles.tagEdit.Value = text;
        end
        
        function onDistanceEdit(obj)
            % Wheel.onDistanceEdit()
            % Capture changes to the distance text-box.
            
            obj.handles.distanceEdit.Value = obj.handles.distanceEdit.Value{1};
            if parsePositiveFloat(obj.handles.distanceEdit.Value{1})
                obj.handles.distanceEdit.BackgroundColor = Wheel.colors.valid;
            else
                obj.handles.distanceEdit.BackgroundColor = Wheel.colors.invalid;
            end
        end
        
        function onSetLock(obj)
            % Wheel.onSetLock()
            % Capture Set button presses.
            
            [valid, distance] = parsePositiveFloat(obj.handles.distanceEdit.Value{1});
            if valid
                for t = obj.getSelection()
                    obj.setLock(obj.tags{t}, distance);
                end
            end
        end
        
        function selection = getSelection(obj)
            if any(obj.tagListSelection)
                selection = find(obj.tagListSelection);
            else
                selection = 1:numel(obj.tags);
            end
        end
        
        function onAddLock(obj)
            % Wheel.onAddLock()
            % Capture Add button presses.
            
            [valid, distance] = parsePositiveFloat(obj.handles.distanceEdit.Value{1});
            if valid
                for t = obj.getSelection()
                    obj.addLock(obj.tags{t}, distance);
                end
            end
        end
        
        function onScheduleLock(obj)
            % Wheel.onScheduleLock()
            % Capture Schedule button presses.
            
            distanceText = strtrim(obj.handles.distanceEdit.Value{1});
            [distanceValid, distance] = parsePositiveFloat(distanceText);
            if distanceValid
                lockTime = inputdlg('Input target time in format HHMMSS', [mfilename('class'), ' - Schedule lock'], [1, 40], {'235959'}, struct('WindowStyle', 'modal'));
                if ~isempty(lockTime)
                    lockTime = strtrim(lockTime{1});
                    lockTimeValid = false;
                    if ~isempty(regexp(lockTime, '^\d{6}$', 'ONCE'))
                        h = str2double(lockTime(1:2));
                        m = str2double(lockTime(3:4));
                        s = str2double(lockTime(5:6));
                        if h >= 0 && h <= 23 && m >= 0 && m <= 59 && s >= 0 && s <= 59
                            lockTimeValid = true;
                            for t = obj.getSelection()
                                obj.scheduleLock(obj.tags{t}, distance, h, m, s);
                            end
                        end
                    end
                    if ~lockTimeValid
                        errordlg(sprintf('"%s" is not a valid time format; please use HHMMSS.', lockTime), [mfilename('Class') ' - Schedule lock error'], 'modal');
                    end
                end
            else
                errordlg(sprintf('"%s" is not a valid distance.', distanceText), [mfilename('Class') ' - Schedule lock error'], 'modal');
            end
        end
        
        function onTagEdit(obj)
            % Wheel.onTagEdit()
            % Capture changes to the tag text-box.
            
            inputs = strjoin(obj.handles.tagEdit.Value, ' ');
            inputs = strtrim(regexprep(inputs, '[,;]+', ' '));
            inputs = strsplit(inputs);
            if any(cellfun(@isempty, regexp(inputs, '^[0-9A-F]{10}$', 'start', 'once')))
                valid = false;
                inputs = {};
            else
                valid = true;
            end
            if valid
                obj.handles.tagEdit.BackgroundColor = Wheel.colors.valid;
                newTags = setdiff(inputs, obj.tags);
                for t = 1:numel(newTags)
                    tag = newTags{t};
                    obj.setDistance(tag, 0);
                end
                obj.tagListSelection = ismember(obj.tags, inputs);
                obj.updateTagList();
            else
                obj.handles.tagEdit.BackgroundColor = Wheel.colors.invalid;
            end
        end
        
        function updateTagList(obj)
            % Wheel.updateTagList()
            % Populate tag list with available tags.
            
            list = cell(size(obj.tags));
            for t = 1:numel(obj.tags)
                tag = obj.tags{t};
                state = obj.tagStates(tag);
                lockDistanceFormatted = sprintf('%.2f', state.lockDistance);
                scheduleLockDistanceFormatted = sprintf('%.2f', state.scheduleLockDistance);
                if state.scheduleLock
                    hms = sprintf('%0*i', 6, state.scheduleLockTime);
                    list{t} = sprintf('%s Lock:%s (%s@%s:%s:%s)', tag, lockDistanceFormatted, scheduleLockDistanceFormatted, hms(1:2), hms(3:4), hms(5:6));
                else
                    list{t} = sprintf('%s Lock:%s ', tag, lockDistanceFormatted);
                end
            end
            obj.handles.tagList.Items = list;
            if any(obj.tagListSelection)
                obj.handles.tagEdit.Value = obj.tags(obj.tagListSelection);
                obj.handles.tagList.Value = list(1, obj.tagListSelection);
            end
        end
        
        function stopTimer(obj)
            % Wheel.stopTimer()
            % Stop background timer once.
            
            if ~obj.timerStopped
                obj.timerStopped = true;
                stop(obj.ticker);
                delete(obj.ticker);
            end
        end
        
        function distance = getDistance(obj, tag)
            % distance = Wheel.getDistance()
            % Get distance of a given tag.
            
            obj.initializeTagState(tag);
            distance = obj.tagStates(tag).distance;
        end
        
        function setDistance(obj, tag, distance)
            % Wheel.getDistance()
            % Set distance for a given tag.
            
            obj.setTagState(tag, 'distance', distance);
            obj.setTagState(tag, 'times', [obj.tagStates(tag).times; obj.elapsed()]);
            obj.setTagState(tag, 'distances', [obj.tagStates(tag).distances; distance]);
        end
        
        function time = elapsed(obj)
            % Wheel.elapsed()
            % Get time from startup.
            
            time = toc(obj.startTic);
        end
        
        function debug(obj, text, varargin)
            % Wheel.debug(format, var1, var2, ...)
            % Print a message on the screen using fprintf syntax.
            
            if obj.debugging
                fprintf([sprintf('[%.2f] ', obj.elapsed()), text, '\n'], varargin{:});
            end
        end
        
        function onLoop(obj)
            % Wheel.onLoop()
            % Timer capture function.
            
            % Handle errors that MATLAB would otherwise report as warnings.
            try
                obj.loop();
            catch exception
                str = sprintf( 'Error: %s\n', exception.message);
                for stack = transpose(exception.stack)
                    [ ~, filename] = fileparts(stack.file);
                    str = sprintf('%s%s', str, sprintf(['In <a href="matlab:matlab.desktop.editor.openAndGoToLine', '("%s",%i);">%s.%s (line: %i)</a>\n'], stack.file, stack.line, filename, stack.name, stack.line));
                end
                stop(obj.ticker);
                % Release resources.
                obj.dispose();
                % Display formatted stack trace.
                disp(str);
            end
        end
        
        function loop(obj)
            % Wheel.loop()
            % Actual timer function.
            
            time = obj.elapsed();
            obj.portProbe.step();
            
            if time >= obj.tickerNext
                obj.tickerNext = time + Wheel.tickerInterval;
                % Scan ports regularly.
                obj.visiblePorts = serialportlist("all");
                obj.visiblePorts = obj.visiblePorts.cellstr();
                obj.closeDisconnected();
                if obj.scanning
                    obj.openConnected();
                end
                
                % Reset distance regularly.
                hms = HMS();
                timeBlock = round(hms / obj.tickerInterval);
                for t = 1:numel(obj.tags)
                    tag = obj.tags{t};
                    state = obj.tagStates(tag);
                    if state.scheduleLock
                        % Double-check schedule triggering.
                        gracePeriod = 5 * obj.tickerInterval;
                        if state.scheduleLockArmed && hms >= state.scheduleLockTime && hms <= state.scheduleLockTime + gracePeriod
                            obj.addLock(tag, state.scheduleLockDistance, false);
                            obj.setTagState(tag, 'scheduleLockArmed', false);
                        elseif ~state.scheduleLockArmed && hms > state.scheduleLockTime + gracePeriod
                            obj.setTagState(tag, 'scheduleLockArmed', true);
                        end
                    end
                    
                    testBlock = round(state.scheduleLockTime / obj.tickerInterval);
                    if state.scheduleLock && timeBlock == testBlock
                        obj.addLock(tag, state.scheduleLockDistance, false);
                    end
                end
            end
            
            if obj.scanning
                % Check each port for new data or inactivity.
                nPorts = numel(obj.ports);
                for p = 1:nPorts
                    name = obj.ports(p).name;
                    newData = false;
                    if obj.ports(p).opened
                        % Read and buffer all incoming data.
                        bytes = read(obj.ports(p).device);
                        obj.ports(p).bytes = cat(1, obj.ports(p).bytes(:), bytes);
                        newData = numel(bytes) > 0;
                        
                        if obj.ports(p).compatible == Wheel.trio.true
                            % Check for regular activity.
                            if time >= obj.ports(p).ticker + Wheel.tickerInterval
                                obj.closePort(name);
                                obj.setConnectionStatus(name, 'inactive');
                                obj.debug('%s: loop !opened/!active', name);
                            end
                        elseif obj.ports(p).compatible == Wheel.trio.unset
                            % Compatibility check: connection settle, request handshake, wait for reply.
                            if time >= obj.ports(p).ticker + Wheel.tickerInterval
                                if obj.ports(p).greeted
                                    obj.closePort(name);
                                    obj.ports(p).compatible = Wheel.trio.false;
                                    obj.setConnectionStatus(name, 'incompatible');
                                    obj.debug('%s: loop !opened/!compatible', name);
                                else
                                    obj.ports(p).greeted = true;
                                    obj.ports(p).ticker = time;
                                    write(obj.ports(p).device, 255, 'uint8');
                                end
                            end

                            if newData && obj.ports(p).opened == true && obj.ports(p).compatible ~= Wheel.trio.true
                                % Data synchronization (255 x nSync).
                                [counts, numbers] = sequence(obj.ports(p).bytes == 255);
                                k = counts >= Wheel.nSync & numbers;
                                if any(k)
                                    obj.ports(p).compatible = Wheel.trio.true;
                                    % Remove data prior to sync and sync itself.
                                    b = sum(counts(1:find(k, 1) - 1)) + Wheel.nSync + 1;
                                    obj.ports(p).bytes = obj.ports(p).bytes(b:end);
                                    obj.ports(p).ticker = time;
                                    if ishandle(obj.ports(p).line)
                                        color = obj.ports(p).line.Color;
                                        delete(obj.ports(p).line);
                                        obj.ports(p).line = plot(obj.handles.temperatureAxes, NaN, NaN, 'Marker', 'none', 'LineStyle', '-', 'Color', color);
                                    else
                                        obj.ports(p).line = plot(obj.handles.temperatureAxes, NaN, NaN, 'Marker', 'none', 'LineStyle', '-');
                                    end
                                    obj.setConnectionStatus(name, 'connected');
                                    obj.debug('%s: loop active/compatible', name);
                                end
                            end
                        end
                    end
                    
                    if obj.ports(p).opened == true && obj.ports(p).compatible == Wheel.trio.true
                        % Parse new data from compatible ports.
                        if newData
                            obj.ports(p).ticker = time;
                            
                            % Instruction: command followed by parameter(s)
                            bytes = obj.ports(p).bytes;
                            nBytes = numel(bytes);
                            busy = nBytes >= 1;
                            k = 0;
                            while busy
                                command = bytes(k + 1);
                                switch command
                                    case 0 % Step: 0 | 1 --> -1 | 1
                                        if nBytes - k >= 2
                                            k = k + 2;
                                            step = bytes(k);
                                            if step == 0
                                                step = -1;
                                            end
                                            tag = obj.ports(p).tag;
                                            arc = obj.radius * 2 * pi / obj.nHallSensors;
                                            obj.setDistance(tag, obj.getDistance(tag) + abs(step) * arc);
                                            obj.updateLock(name, tag);
                                            % obj.debug('%s:step: %2.f', name, step);
                                            obj.log(name, tag, step);
                                        else
                                            busy = false;
                                        end
                                    case 1 % Temperature: 0 <= t <= 1024
                                        if nBytes - k >= 3
                                            k = k + 3;
                                            v = bytes(k - 1) + bitshift(bytes(k), 8);
                                            % Convert voltage to celcius
                                            temperature = 100 * v * obj.voltage / 1024 - 50;
                                            obj.ports(p).times(end + 1) = time;
                                            obj.ports(p).temperatures(end + 1) = temperature;
                                            obj.ports(p).temperature = temperature;
                                            set(obj.ports(p).line, 'XData', obj.ports(p).times(:), 'YData', obj.ports(p).temperatures(:));
                                            if time >= obj.temperatureNext - Wheel.temperatureInterval / 2 % !!
                                                obj.temperatureNext = time + Wheel.temperatureInterval;
                                                tag = obj.ports(p).tag;
                                                obj.log(name, tag, 0);
                                            end
                                            % obj.debug('%s:temperature: %.2f', name, celsius);
                                        else
                                            busy = false;
                                        end
                                    case 2 % Tag: STX ... ETX
                                        stx = find(bytes(k + 1:end) == 2, 1) + k;
                                        etx = find(bytes(k + 1:end) == 3, 1) + k;
                                        if stx < etx
                                            k = etx;
                                            tag = upper(char(bytes(stx + 1:etx - 3))');
                                            cs = upper(char(bytes(etx - 2:etx - 1))');
                                            if ~isequal(checksum(tag), cs)
                                                tag = Wheel.noTag;
                                                if obj.verbose
                                                    fprintf(2, '%s: Failed to read tag.\n', name);
                                                end
                                            end
                                            obj.ports(p).tag = tag;
                                            obj.initializeTagState(tag);
                                            obj.updateLock(name, tag);
                                            obj.debug('%s tag:%s', name, tag);
                                            obj.log(name, tag, 0);
                                        else
                                            busy = false;
                                        end
                                    case 4 % ping/state: 0 | 1
                                        if nBytes - k >= 2
                                            k = k + 2;
                                            tag = obj.ports(p).tag;
                                            lock = obj.getDistance(tag) >= obj.getLock(tag);
                                            locked = bytes(k) == Wheel.lockStates.locked;
                                            if lock ~= locked
                                                obj.updateLock(name, tag);
                                            end
                                        else
                                            busy = false;
                                        end
                                    case 5 % WheelID: 0 <= id <= 255
                                        if nBytes - k >= 2
                                            k = k + 2;
                                            id = bytes(k);
                                            obj.ports(p).id = id;
                                            obj.setConnectionStatus(name, 'connected');
                                            obj.debug('%s:id: %i', name, id);
                                        else
                                            busy = false;
                                        end
                                    otherwise
                                        busy = false;
                                        obj.closePort(name);
                                        obj.setConnectionStatus(name, 'not in sync');
                                        obj.debug('%s|%s: loop !opened/!sync', name, obj.ports(p).tag);
                                end
                                busy = busy && k < numel(bytes);
                            end
                            % Remove read bytes.
                            obj.ports(p).bytes(1:k) = [];
                            obj.ports(p).bytes = obj.ports(p).bytes(:);
                        end
                    end
                end
                
                % Update distance trails.
                xlims = [max(0, time - obj.plotTrail), time];
                for t = 1:numel(obj.tags)
                    tag = obj.tags{t};
                    if ishandle(obj.tagStates(tag).line)
                        [x, y] = trail(obj.tagStates(tag).times, obj.tagStates(tag).distances, xlims);
                        set(obj.tagStates(tag).line, 'XData', x, 'YData', y);
                    end
                end
                
                % Updated temperature trails.
                for p = 1:nPorts
                    [x, y] = trail(obj.ports(p).times, obj.ports(p).temperatures, xlims);
                    if ishandle(obj.ports(p).line)
                        set(obj.ports(p).line, 'XData', x, 'YData', y);
                    end
                end
                
                % Adjust ylims.
                if ~isempty(obj.handles.temperatureAxes.Children)
                    y = cat(2, obj.handles.temperatureAxes.Children.YData);
                    if ~isempty(y)
                        ylim(obj.handles.temperatureAxes, [min(y) - 2, max(y) + 2]);
                    end
                end
                if ~isempty(obj.handles.distanceAxes.Children)
                    y = cat(2, obj.handles.distanceAxes.Children.YData);
                    if ~isempty(y)
                        ylim(obj.handles.distanceAxes, [min(y) - 5, max(y) + 5]);
                    end
                end
                xlim(obj.handles.temperatureAxes, xlims);
                xlim(obj.handles.distanceAxes, xlims);
            end
        end
        
        function closePort(obj, name)
            % Wheel.closePort(name)
            % Close port and reset states to default.
            
            registeredPorts = {obj.ports.name};
            p = ismember(registeredPorts, name);
            obj.ports(p).opened = false;
            if obj.ports(p).compatible ~= Wheel.trio.false
                obj.ports(p).compatible = Wheel.trio.unset;
            end
            obj.ports(p).available = Wheel.trio.unset;
            obj.ports(p).greeted = false;
            % Clear line, then close.
            try
                fclose(obj.ports(p).device);
            catch
            end
        end
        
        function log(obj, name, tag, direction)
            % Wheel.log(name, tag, direction)
            % Create an entry in the log file. Entries require a port name,
            % an RFID tag and a rotation direction.
            
            p = ismember({obj.ports.name}, name);
            filename = fullfile(obj.rootFolder, sprintf('%s.csv', tag));
            newFile = exist(filename, 'file') ~= 2;
            success = false;
            if isKey(obj.fileIds, tag)
                fid = obj.fileIds(tag);
                success = true;
            else
                fid = fopen(filename, 'a');
                if fid >= 0
                    obj.fileIds(tag) = fid;
                    success = true;
                end
            end
            entry = sprintf('%s,%s,%s,%.2f,%i,%.2f,%.2f,%.2f,%.2f\n', tag, obj.session, datestr(now, 'yyyymmddHHMMSS'), obj.elapsed(), obj.ports(p).id, obj.ports(p).temperature, obj.getLock(tag), obj.getDistance(tag), direction);
            if obj.verbose
                fprintf(entry);
            end
            if success
                if newFile
                    header = 'tag-id, start-time, current-time, elapsed (s), wheel-id, temperature (celsius), locking-distance (cm), distance (cm), direction\n';
                    fprintf(fid, header);
                end
                try
                    fprintf(fid, entry);
                catch
                    success = false;
                end
            end
            if success
                if isKey(obj.handles.dialogs, filename)
                    delete(obj.handles.dialogs(filename));
                    remove(obj.handles.dialogs, filename);
                end
            elseif ~isKey(obj.handles.dialogs, filename) || ~ishandle(obj.handles.dialogs(filename))
                 obj.handles.dialogs(filename) = errordlg(sprintf('Data could not be saved to "%s". Close any programs using this file.', filename), [mfilename('Class') ' - Log error'], 'non-modal');
            end
        end
        
        function updateLock(obj, name, tag)
            % Wheel.updateLock(name, tag)
            % Send a command to the serial port with the given name to lock
            % or unlock the servo according to the distance and locking
            % distance associated to a tag.
            
            if nargin == 1
                for p = 1:numel(obj.ports)
                    obj.updateLock(obj.ports(p).name, obj.ports(p).tag);
                end
            else
                p = ismember({obj.ports.name}, name);
                if any(p) && obj.ports(p).opened && obj.ports(p).compatible == Wheel.trio.true
                    lock = obj.getDistance(tag) >= obj.getLock(tag);
                    if lock
                        write(obj.ports(p).device, Wheel.lockStates.locked, 'uint8');
                    else
                        write(obj.ports(p).device, Wheel.lockStates.unlocked, 'uint8');
                    end
                end
            end
        end
        
        function openConnected(obj)
            % Wheel.openConnected()
            % Open visible serial ports to test compatibility.
            
            nPorts = numel(obj.ports);
            device = @serial;
            
            % Open unregistered ports.
            registeredPorts = {obj.ports.name};
            testPorts = setdiff(obj.visiblePorts, registeredPorts);
            for i = 1:numel(testPorts)
                p = nPorts + i;
                name = testPorts{i};
                obj.ports(p).name = name;
                obj.ports(p).device = device(name, 'baudrate', Wheel.baudrate);
                obj.ports(p).device.Timeout = 1e-3;
                obj.ports(p).bytes = zeros(0, 1);
                obj.ports(p).opened = false;
                obj.ports(p).available = Wheel.trio.unset;
                obj.ports(p).compatible = Wheel.trio.unset;
                obj.ports(p).greeted = false;
                obj.ports(p).ticker = obj.elapsed();
                obj.ports(p).id = 0;
                obj.ports(p).tag = Wheel.noTag;
                obj.ports(p).temperature = [];
                obj.ports(p).temperatures = [];
                obj.ports(p).times = [];
                obj.ports(p).line = NaN;
                obj.portProbe.probe(name, @(available)obj.onConnectionSettled(name, available));
            end
            registeredPorts = {obj.ports.name};
            
            % Open closed ports.
            k = [obj.ports.opened] == false & [obj.ports.compatible] ~= Wheel.trio.false;
            testPorts = intersect(registeredPorts(k), obj.visiblePorts);
            for i = 1:numel(testPorts)
                name = testPorts{i};
                obj.portProbe.probe(name, @(available)obj.onConnectionSettled(name, available));
            end
        end
        
        function onConnectionSettled(obj, name, available)
            % Wheel.onConnectionSettled()
            % Connection between serial port and OS settle.
            
            testPorts = {obj.ports.name};
            p = ismember(testPorts, name);
            
            if available
                try
                    fopen(obj.ports(p).device);
                catch
                    available = false;
                    obj.setConnectionStatus(name, 'unavailable');
                end
            else
                obj.setConnectionStatus(name, 'connecting');
            end
            obj.ports(p).bytes = zeros(0, 1);
            if available
                obj.ports(p).opened = true;
                obj.ports(p).available = Wheel.trio.true;
                obj.ports(p).ticker = obj.elapsed();
                obj.setConnectionStatus(name, 'handshaking');
                obj.debug('%s: scan-new opened/available', name);
            else
                obj.ports(p).available = Wheel.trio.false;
                obj.debug('%s: scan-new !opened/!available', name);
            end
        end
        
        function closeDisconnected(obj)
            % Wheel.closeDisconnected()
            % Close opened, registered ports that are no longer visible.
            
            k = [obj.ports.opened] == true;
            registeredPorts = {obj.ports.name};
            testPorts = setdiff(registeredPorts(k), obj.visiblePorts);
            for i = 1:numel(testPorts)
                name = testPorts{i};
                obj.closePort(name);
                obj.setConnectionStatus(name, 'removed');
                obj.debug('%s: scan-remove', name);
            end
        end
        
        function setConnectionStatus(obj, name, status)
            % Wheel.setConnectionStatus(name, status)
            % Change the legend corresponding to a wheel so it corresponds
            % with the connection status.
            
            testPorts = {obj.ports.name};
            p = ismember(testPorts, name);
            if any(p)
                port = obj.ports(p);
                if ishandle(port.line)
                    set(port.line, 'DisplayName', sprintf('Wheel %02i - %s', port.id, status));
                end
            end
        end
    end
end

function bytes = read(device)
    % read(device)
    % Read bytes from serial device.
    
    bytes = [];
    nBytes = device.BytesAvailable;
    if isvalid(device) && nBytes > 0
        try
            bytes = fread(device, nBytes, 'uint8');
        catch
        end
    end
end

function write(varargin)
    % write(varargin)
    % Replicate fwrite functionality, but capture and ignore all errors.
    
    try
        fwrite(varargin{:});
    catch
    end
end

function [counts, numbers] = sequence(data)
    % [counts, numbers] = sequence(data)
    % Represent a sequence of values as interrupted counts. For example:
    % [counts, numbers] = sequence([10 20 20 30 30 30 40 50])
    % %  counts -->  1,  2,  3,  1,  1
    % % numbers --> 10, 20, 30, 40, 50
    
    data = data(:);
    if isempty(data)
        counts = [];
        numbers = [];
    else
        m = cat(1, find(diff(data)), numel(data));
        counts = cat(1, m(1), diff(m));
        numbers = data(m);
    end
end

function cs = checksum(hex)
    % cs = checksum(hex)
    % Apply XOR operator on equal bit positions across all hex values.
    
    n = numel(hex) / 2;
    hex = reshape(hex(:), 2, n)';
    bin = dec2bin(hex2dec(hex)) == '1';
    current = bin(1, :);
    for i = 2:size(bin, 1)
        current = xor(bin(i, :), current);
    end
    falseTrue = '01';
    cs = dec2hex(bin2dec(falseTrue(1 + current)), 2);
end

function [valid, number] = parsePositiveFloat(text)
    % [valid, number] = parsePositiveFloat(text)
    % Get a positive float from a string, return 0 if invalid.
    
    try
        number = str2double(text);
        valid = numel(number) == 1 & ~isnan(number) & number >= 0;
    catch
        valid = false;
    end
    if ~valid
        number = 0;
    end
end

function [x, y] = trail(x, y, xlims)
    % [x, y] = trail(x, y, xlims)
    % Crop x and y so they are within xlims(1) and xlims(2)
    
    x = x(:);
    y = y(:);
    if isempty(x)
        x = [];
        y = [];
    else
        k1 = find(x <= xlims(1), 1, 'last');
        k2 = find(x >= xlims(2), 1, 'first');
        if isempty(k1)
            x = [xlims(1); x];
            y = [y(1); y];
        else
            xlims(1) = x(k1);
        end
        if isempty(k2)
            x = [x; xlims(2)];
            y = [y; y(end)];
        else
            xlims(2) = x(k2);
        end
    end
    k = x >= xlims(1) & x <= xlims(2);
    x = x(k);
    y = y(k);
end

function t = HMS()
    % t = HMS()
    % Return a number encoding hour, minute and second of the day.

    t = datevec(now);
    t = sum(round(t(4:6) .* [10000, 100, 1]));
end