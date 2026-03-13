import numpy as np
from numpy import interp


# Func to convert pixel intensity value to spike emission interval using deterministic rate coding
def rateCoding_Deterministic_Spike_Interval(intensity):
    T = 100 # ms
    freqHigh = 200 # Spike/sec
    freqLow = 10 # Spike/sec 

    '''
        0. Normalize the input pixel intensity value to be between 0 and 1
    '''
    pVal = intensity/255 # Normalized pixel intensity value assuming 8 bit pixel intensity range (0-255)

    '''
        1. Calculated the low and high frequencies using the retinal firing rates (10,200)
    '''
    ffs = freqHigh * T * 1/1000 # full frequency state
    lfs = freqLow  * T * 1/1000 # low frequency state
    '''
        2. Interpolate the input pixel intensity value using the retinal firing rates as points
    '''
    f_det = interp(pVal, [0,lfs], [1,ffs]) # deterministic frequency
    '''
        3. Generate the spike emission interval
    '''
    spike_emission_interval = int(T/f_det) # spike emission interval
    

    return (spike_emission_interval)

#Func to create a text file to store the spike emission intervals for a range of pixel intensity values
# 8 bit address space with pixel intensity range (0-255), there for use will use 8 bit memory
# Each 8 bit word  would contain the corresponding spike emission interval
# to make it easier to implemnet in verilog
# we'll create the text file as using the memory name (eg: mem), then save each memory value as used in verilog (eg: mem[0] = 8'b00000000; for the corresponding spike emission interval 0)
# Finally let's save the text file as preffered, by default save at the current working directory with the name 'spike_intervals_hash_map.txt'
def create_mem_file_for_spike_intervals(file_name = 'spike_intervals.txt', memory_name = 'mem', max_intensity = 256):
    
    #Convering max_intensity to intensity range 
    intensity_range = range(max_intensity)

    # Fill the memory-mapped file with spike emission intervals for each pixel intensity value in the range, intially print
    with open(file_name, 'w') as f:
        for i, intensity in enumerate(intensity_range):
            value = rateCoding_Deterministic_Spike_Interval(intensity)
            # Format the memory value as 8-bit binary string (8 bits for spike interval)
            mem_value = f"{value:08b}"
            f.write(f"{memory_name}[{i}] = 8'b{mem_value};\n")
    


# For 8 bit pixel intensity range (0-255)
intensity_range = range(256)
# Create a memory-mapped file to store the spike emission intervals for the pixel intensity range
create_mem_file_for_spike_intervals('spike_intervals.dat','mem', 256)
