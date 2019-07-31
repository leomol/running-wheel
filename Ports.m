% Ports - Check anynchronously if and when a serial port is ready for a connection.
% 
% Example:
%   ports = Ports('COM10', @disp);
%   while ports.step()
%   end
%   % If the port is not connected or unavailable it will display 0. If the
%   % port is connected, it will display 1 when it is ready for use.

% 2019-05-12. Leonardo Molina.
% 2019-06-03. Last modified.
classdef Ports < handle
    properties (Dependent)
        busy
    end
    
    properties (Access = private)
        process
        ports = cell(1, 0)
        callbacks = cell(1, 0)
    end
    
    methods
        function obj = Ports(port, callback)
            obj.process = PowerShell();
            if nargin == 2
                obj.probe(port, callback);
            end
        end
        
        function delete(obj)
            delete(obj.process);
        end
        
        function busy = step(obj)
            busy = obj.process.step();
        end
        
        function busy = get.busy(obj)
            busy = obj.process.busy;
        end
        
        function probe(obj, port, callback)
            % Command template.
            command = '$port=new-Object System.IO.Ports.SerialPort %s,4800,None,8,one;$port.open();';
            command = sprintf(command, port);
            
            k = ismember(obj.ports, port);
            if any(k)
                obj.callbacks{k} = callback;
            else
                obj.ports{end + 1} = port;
                obj.callbacks{end + 1} = callback;
            end
            obj.process.callback = @(response)obj.forward(port, response);
            obj.process.run(command);
        end
    end
    
    methods (Access = private)
        function forward(obj, port, response)
            k = ismember(obj.ports, port);
            callback = obj.callbacks{k};
            if isempty(response)
                callback(true);
            else
                callback(false);
            end
        end
    end
end