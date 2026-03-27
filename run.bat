:: TODO run.bat

@echo off
echo Compiling Verilog files from src/ and tb/...

:: -I src/ helps find defines.v
:: src/*.v includes all hardware modules
:: tb/*.v includes your testbench
iverilog -I src/ -o cpu_sim src/*.v tb/*.v

if %errorlevel% neq 0 (
    echo Compilation Failed.
    pause
    exit /b %errorlevel%
)

echo Compilation Successful. Starting Simulation...

:: Run the simulation
vvp cpu_sim

if exist cpu_sim.vcd (
    echo Opening GTKWave...
    gtkwave cpu_sim.vcd
) else (
    echo Error: cpu_sim.vcd not found. Check tb_cpu.v for $dumpfile.
)

pause