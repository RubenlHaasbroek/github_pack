
%% Temperature controller calculations
% Ruben Haasbroek, 26865238. Controller from pid.py.

clear; clc;

%% Settings
Kp = 0.15;      % 1/degC
Ki = 0.015;     % 1/(degC s)
P  = 6;         % s
dt = 0.5;       % s
umin = -1;
umax = 1;

%% Feedforward fraction
% $$ f_{ff} = \frac{T_{set}-T_{cold}}{T_{hot}-T_{cold}} \qquad (D.4.1) $$
Tset = 37;  Thot = 45.9;  Tcold = 25.3;
fff = (Tset - Tcold)/(Thot - Tcold);
fprintf('f_ff = (%.1f - %.1f)/(%.1f - %.1f) = %.3f\n', Tset, Tcold, Thot, Tcold, fff);

%% PI trim
% $$ e = T_{set} - T_{mix} \qquad (D.4.2) $$
%
% $$ I^* = I + e\,\Delta t \qquad (D.4.3) $$
%
% $$ u = K_p\,e + K_i\,I^* \qquad (D.4.4) $$
%
% The integral only updates when u is between -1 and 1 (D.4.5). The trim is
% then limited to -1 and 1 (D.4.6).

% Example 1: start-up, outlet at 28.0 degC, integral at zero
Tmix = 28.0;  I = 0;
e = Tset - Tmix;
Istar = I + e*dt;
u = Kp*e + Ki*Istar;
fprintf('e = %.1f degC, I* = %.2f, u = %.4f\n', e, Istar, u);
if u >= umin && u <= umax
    I = Istar;
else
    fprintf('u is outside the limits, integral stays at %.1f\n', I);
end
trim1 = min(umax, max(umin, u));
d1 = min(1, max(0, fff + trim1));
fprintf('trim = %.1f, d = %.3f\n', trim1, d1);

% Example 2: outlet at 39.0 degC, integral at 10 degC s
Tmix = 39.0;  I = 10;
e = Tset - Tmix;
Istar = I + e*dt;
u = Kp*e + Ki*Istar;
fprintf('e = %.1f degC, I* = %.2f, Kp*e = %.3f, Ki*I* = %.3f, u = %.3f\n', e, Istar, Kp*e, Ki*Istar, u);

%% Hot duty fraction
% $$ d = f_{ff} + u \qquad (D.4.7) $$
% with d limited to 0 and 1.
d2 = min(1, max(0, fff + u));
fprintf('d = %.3f + (%.3f) = %.3f\n', fff, u, d2);
fprintf('hot time in one period = %.2f s of %g s\n', d2*P, P);

%% Valve switching
% The hot valve is open while
%
% $$ \tau < d\,P \qquad (D.4.8) $$
%
% where tau is the time into the 6 s period. Example where d changes
% during the period:
tau = 0:dt:P-dt;
d = 0.50*ones(size(tau));
d(tau >= 2.5) = 0.35;
d(tau >= 3.5) = 0.70;
hot = tau < d*P;
fprintf('tau   :'); fprintf(' %4.1f', tau); fprintf('\n');
fprintf('d     :'); fprintf(' %4.2f', d);   fprintf('\n');
fprintf('hot   :'); fprintf(' %4d', hot);   fprintf('\n');
fprintf('valve changes in the period: %d\n', sum(diff(hot) ~= 0));

%% Unequal flows (explanation only, not in the controller)
% $$ T_{mix} = \frac{d\,Q_h\,T_{hot} + (1-d)\,Q_c\,T_{cold}}{d\,Q_h + (1-d)\,Q_c} \qquad (D.4.9) $$
Qh = 4.557;  Qc = 5.180;    % L/min
Tmix = (fff*Qh*Thot + (1-fff)*Qc*Tcold)/(fff*Qh + (1-fff)*Qc);
fprintf('T_mix = %.2f degC, %.2f degC below the setpoint\n', Tmix, Tset - Tmix);