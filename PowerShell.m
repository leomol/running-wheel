% PowerShell - Execute a command in PowerShell asynchronously and receive a
% response when ready.
% 
% Example:
%   shell = PowerShell('echo hello!', @disp);
%   while shell.step()
%   end
%   % When the command finishes executing, this example will display "hello!".

% 2019-05-25. Leonardo Molina.
% 2019-05-29. Last modified.
classdef PowerShell < handle
    properties (Dependent)
        busy
        callback
    end
    
    properties (Access = private)
        retrieved = false
        processBuilder
        inputStream
        process
        isProcess = false
        mCallback = @disp
    end
    
    methods
        function obj = PowerShell(command, callback)
            obj.processBuilder = java.lang.ProcessBuilder({''});
            obj.processBuilder.directory(java.io.File(pwd));
            obj.processBuilder.redirectErrorStream(true);
            if nargin == 2
                obj.callback = callback;
                obj.run(command);
            end
        end
        
        function delete(obj)
            if obj.isProcess
                obj.process.destroy();
            end
        end
        
        function run(obj, command)
            if obj.isProcess
                obj.process.destroy();
            end
            obj.processBuilder.command({'powershell.exe', command});
            obj.process = obj.processBuilder.start();
            obj.inputStream = obj.process.getInputStream();
            obj.isProcess = true;
            obj.retrieved = false;
        end
        
        function busy = get.busy(obj)
            busy = obj.isProcess && obj.process.isAlive == 1;
        end
        
        function callback = get.callback(obj)
            callback = obj.mCallback;
        end
        
        function set.callback(obj, callback)
            if isa(callback, 'function_handle')
                obj.mCallback = callback;
            else
                error(sprintf('%s:SetCallbackError', mfilename('class')), 'Provided argument is not a valid function handle.');
            end
        end
        
        function busy = step(obj)
            busy = obj.busy;
            if obj.isProcess && ~obj.retrieved && obj.process.isAlive == 0
                scanner = java.util.Scanner(obj.inputStream).useDelimiter('\A');
                if scanner.hasNext()
                    response = scanner.next();
                else
                    response = '';
                end
                response = strtrim(char(response));
                obj.retrieved = true;
                obj.callback(response);
            end
        end
    end
end