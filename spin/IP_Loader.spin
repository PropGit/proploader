{IP_Loader.spin

 This is the Micro Boot Loader delivered via IP (Internet Protocol) packets sent to the Propeller over XBee Wi-Fi S6B. It is written to compile
 as a single unit, but for space and delivery reasons is not meant to be transmitted and run as a single unit.

 It can not be downloaded and executed as-is in the standard fashion.  Instead, it is delivered in sections as explained below.

 Using the Propeller IP Loader (Wi-Fi) Protocol, the core of this application ("Micro-Loader Core" through "Constants and Variables") is delivered
 by the very first IP packet; encoded in a compact form of the original Propeller Download Protocol. It then runs and assists with the remainder of
 the download process to deliver the target Propeller Application in a quick and reliable fashion.  The remaining parts of this Micro-Loader
 application ("Finalization") are delivered when needed as special "executable" packets.
 
 Any symbols in the "Constants and Variables" section labeled "[host init]" have their values set by the host before this application image is
 encoded and transmitted via the first packet.   This feature gives the host the ability to configure it for the fastest possible target
 application delivery based on the Propeller Board's known clock speed.

 To Use This Code:
   1) Compile and store a binary image of this code
   2) Run the PropellerStream.exe program
   3) Use the PropellerStream program to load up the binary image
      It will process the image, splitting it into Micro-Loader Core and numerous Finalization sections, and generate separate constant arrays
      suitable for inclusion into Delphi code.
   4) Copy and paste the arrays into the IP Loader host code.
   5) The IP Loader host code will process this information to initialize the proper constant symbols and encode the Micro-Loader Core and
      Finalization sections into packets just before downloading to the Propeller.
 Delivery:
   * A development machine's software (called the host) initiates IP-based connection to the Propeller.
   * The host patches the host-initialized content of the Micro-Loader Core (in this IP_Loader object), encodes it for use by the Propeller's
     built-in boot loader, and transmits it as part of a single packet (which also contains handshake and timing templates).
   * Once the Micro-Loader Core executes, it responds to the host over the serial-to-IP connection with a "ready" signal.  It does this at the
     intial baud rate and then immediately switches to the final baud rate for the remaining communications.
   * The host waits for the "ready" signal and then switches to the final baud rate also.
   * The host then successively delivers target application packets in-order, from the start of image to the end of image, but numbered with
     Packet IDs in reverse order, from the required packet count down to 1.
   * The Micro-Loader Core knows to keep receiving, acknowledging, and writing successive packets to Main RAM until it receives a packet with ID 0.
   * Any packets with ID 0 or less are considered special executable packets; they are simply executed as-is from the packet buffer once received.
   * The special executable packets are formed from code in the Finalization section of this IP_Loader object.  They are delivered only when
     necessary, and do things like verify RAM, program EEPROM, and launch the target application.     

 Revision History:
 v1.3 - 06/29/2015 - Improved documentation and enhanced launch code to set target application's clock mode properly.
 v1.2 - 06/27/2015 - Added EEPROM programming code in Finalization section.
 v1.1 - 09/30/2014 - Added Transmission ID as first long of packet buffer.  Updated Acknowledge routine to send two longs, Expected ID and
        Transmission ID, so host can realize the actual transmission that the positive or negative acknowledgement is responding to. Fixed bug
        in Receive Packet routine that caused it to clear one register beyond the end of the packet buffer.
 v1.0 - 07/28/2014 - First Release; Does not include EEPROM writing feature.
}

CON               
        _clkmode = xtal1+pll16x                                                 'Standard clock mode * crystal frequency = 80 MHz
        _xinfreq = 5_000_000

  MaxPayload = 1392                                                             'Maximum size of packet payload (in bytes)

  JMP_Inst   = %010111_000                                                      'JMP instruction's I+E field  value
  PacketCode = $11111111                                                        'Executable packet code marker; used to strip separate
                                                                                'executable packets from the end of the Application Image
  
PUB Main             

  coginit(0, @Loader, 0)

DAT
{IP Loader PASM.  Runs in cog to receive target application at high-speed (compared to standard Propeller Download Protocol).

Timing: Critical routine timing is shown in comments, like '4 and '6+, indication clock cycles instruction consumes.
        'n       : n clock cycles
        'n+      : n or more clock cycles
        'n/m     : n cycles (if jumping) or m cycles (if not jumping)
        'x/n     : don't care (if executed) or n cycles (if not executed)
        'n![m+]  : n cycles til moment of output/input, routine's iteration time is m or more cycles moment-to-moment
        'n![m/l] : like above except inner-loop iteration time is m cycles moment-to-moment, outer-loop is l cycles moment-to-moment
        'n!(m)   : like above except m is last moment to this critical moment (non-iterative)

        * MaxRxSenseError : To support the FailSafe and EndOfPacket timeout feature, the :RxWait routine detects the edges of start bits with
                            a polling loop.  This means there's an amount of edge detection error equal to the largest number of clock cycles
                            starting from 1 cycle after input pin read to the moment the 1.5x bit period window is calculated.   This cycle
                            path is indicated in the :RxWait routine's comments along with the calculated maximum error.  This value should
                            be used as the MaxRxSenseError constant in the host software to adjust the 1.5x bit period downward so that the
                            bit sense moment is closer to ideal in practice.
}

'***************************************
'*          Micro-Loader Core          *
'***************************************
        
                            org     0                    
                            {Initialize Tx pin}                                 
  Loader                    mov     outa, TxPin                                 'Tx Pin to output high (resting state)
                            mov     dira, TxPin
                                    
                            {Wait for resting RxPin}
                            mov     BitDelay, BitTime       wc                  'Prep wait for 1/2 bit periods; clear c for first :RxWait
                            shr     BitDelay, #1
                            add     BitDelay, cnt
    :RxWait   if_nc         mov     TimeDelay, #8*20                            'If RxPin active (c=0), reset sample count; 8 bytes * 20 samples/byte
                            waitcnt BitDelay, BitTime
                            test    RxPin, ina              wc                  '           Check Rx state; c=0 (active), c=1 (resting)
                            djnz    TimeDelay, #:RxWait                         'Rx busy? Loop until resting 8 byte periods

                            {Send ACK/NAK + TID (Transmission ID).  Note that first
                             ACK, at initial baud rate, serves as "Ready" signal}
  Acknowledge               movd    :TxBit, #ExpectedID                         'Ready acknowledgement; 'ACK=next packet ID, NAK=previous packet ID
                            mov     RcvdTransID, TransID                        'Ready Transmission ID; ID of transmission prompting this response                  
                            mov     Longs, #2                                   'Ready 2 longs
                            mov     BitDelay, BitTime                           'Prep start bit window / ensure prev. stop bit window
                            add     BitDelay, cnt
    :TxLong                 mov     Bytes, #4                       '4          'Ready 4 bytes (each long)
    :TxByte                 mov     Bits, #8                        '4          '  Ready 8 bits (each byte)
                            waitcnt BitDelay, BitTime               '6+         '    Wait for edge of start bit window
                            andn    outa, TxPin                     '4!(18+)    '    Output start bit (low)
    :TxBit                  ror     ExpectedID{addr}, #1    wc      '4          '    Get next data bit
                            waitcnt BitDelay, BitTime               '6+         '      Wait for edge of data bit window
                            muxc    outa, TxPin                     '4!(x)[18+] '      Output data bit
                            djnz    Bits, #:TxBit                   '4/8        '    Loop for next data bit
                            waitcnt BitDelay, BitTime               '6+         '    Wait for edge of stop bit window
                            or      outa, TxPin                     '4!(18+)    '    Output stop bit (high)
                            djnz    Bytes, #:TxByte                 '4/8        '  Loop for next byte of long
                            add     :TxBit, IncDest                 '4          '  Get next long
                            djnz    Longs, #:TxLong                 '4/x        'Loop for next long

                            {Set final bit period and failsafe timeout}
                            mov     BitTime, FBitTime                           'Ensure final bit period for high-speed download
                            movs    :NextPktByte, #Failsafe         '4          'Reset timeout to Failsafe; restart Propeller if comm. lost between packets
                            
                            {Receive packet into Packet buffer}                        
                            mov     PacketAddr, #Packet                                 'Reset packet pointer
    :NextPktLong            movd    :BuffAddr+0, PacketAddr         '4                  'Point 'Packet{addr}' (dest field) at Packet buffer
                            movd    :BuffAddr+1, PacketAddr         '4          
                            movd    :BuffAddr+2, PacketAddr         '4
                            mov     Bytes, #4                       '4                  '  Ready for 1 long
    :NextPktByte            mov     TimeDelay, Timeout{addr}        '4                  '  Set timeout; FailSafe on entry, EndOfPacket on reentry
                            mov     BitDelay, BitTime1_5    wc      '4                  '    Prep first bit sample window; c=0 for first :RxWait
                            mov     SByte, #0                       '4
    :RxWait                 muxc    SByte, #%0_1000_0000    wz      '4            ┌┐    '    Wait for Rx start bit (falling edge); Prep SByte for 8 bits
                            test    RxPin, ina              wc      '4![12/52/80]┐││    '      Check Rx state; c=0 (not resting), c=1 (resting)
              if_z_or_c     djnz    TimeDelay, #:RxWait             '4/x         └┘│    '    No start bit (z or c)? loop until timeout
              if_z_or_c     jmp     #:TimedOut                      'x/4           │    '    No start bit (z or c) and timed-out? Exit
                            add     BitDelay, cnt                   '4             ┴*23 '    Set time to...             (*See MaxRxSenseError note)
    :RxBit                  waitcnt BitDelay, BitTime               '6+                 '    Wait for center of bit    
                            test    RxPin, ina              wc      '4![22/x/x]         '      Sample bit; c=0/1
                            muxc    SByte, #%1_0000_0000            '4                  '      Store bit
                            shr     SByte, #1               wc      '4                  '      Adjust result; c=0 (continue), c=1 (done)
              if_nc         jmp     #:RxBit                         '4                  '    Continue? Loop until done
    :BuffAddr               andn    Packet{addr}, #$FF              '4                  '    Clear space,
                            or      Packet{addr}, SByte             '4                  '    store value into long (low byte first),
                            ror     Packet{addr}, #8                '4                  '    and adjust long
                            movs    :NextPktByte, #EndOfPacket      '4                  '    Replace Failsafe timeout with EndOfPacket timeout
                            djnz    Bytes, #:NextPktByte            '4/8                '  Loop for all bytes of long
                            add     PacketAddr, #1                  '4                  '  Done, increment packet pointer for next time
                            jmp     #:NextPktLong                   '4                  'Loop in case more arrives

                            {Timed out; no packet?}
    :TimedOut               mov     TimeDelay, :NextPktByte                     'Check type of timeout (no packet or end of packet)
                            and     TimeDelay, #$1FF                                      
                            cmp     TimeDelay, #Failsafe    wz                  'z=no packet, nz=end of packet
  TOVector    if_z          clkset  Reset                                       'If no packet, restart Propeller
                            
                            {Check packet ID}
                            cmps    PacketID, ExpectedID    wz                  'Received expected packet? z=yes
              if_nz         jmp     #Acknowledge                                '  No? Acknowledge negatively (ExpectedID untouched)
                            cmps    ExpectedID, #1          wc,wr               '  Yes; decrement to request next packet and check for executable (c=execute packet; new ExpectedID < 0)
              if_c          jmp     #PacketData                                 'Execute packet?
                                                                                '  Jump to run packet code just received
                            {Copy target packet to Main RAM; ignore duplicate}  'Else, copy packet to Main RAM
                            sub     PacketAddr, #PacketData                     'Make PacketAddr into a loop counter
    :Copy                   wrlong  PacketData{addr}, MemAddr                   'Write packet long to Main RAM
                            add     MemAddr, #4                                 '  Increment Main RAM address
                            add     :Copy, IncDest                              '  Increment PacketData address
                            djnz    PacketAddr, #:Copy                          'Loop for whole packet
                            movd    :Copy, #PacketData                          'Reset PacketData{addr} for next time
                            jmp     #Acknowledge                                'Loop to acknowledge positively
                            
                       
'***************************************
'*       Constants and Variables       *
'***************************************

{Initialized Variables}
  MemAddr       long    0                                                       'Address in Main RAM or External EEPROM
  Zero                                                                          'Zero value (for clearing RAM) and
    Checksum    long    0                                                       '  Checksum (for verifying RAM/EEPROM)
                                                                             
{Constants}                                                                              
  Reset         long    %1000_0000                                              'Propeller restart value (for CLK register)
  IncDest       long    %1_0_00000000                                           'Value to increment a register's destination field
  EndOfRAM      long    $8000                                                   'Address of end of RAM+1
  CallFrame     long    $FFF9_FFFF                                              'Initial call frame value
  Interpreter   long    $0001 << 18 + $3C01 << 4 + %0000                        'Coginit value to launch Spin interpreter
  RxPin         long    |< 31                                                   'Receive pin mask (P31)
  TxPin         long    |< 30                                                   'Transmit pin mask (P30)
  SDAPin        long    |< 29                                                   'EEPROM's SDA pin mask (P29)
  SCLPin        long    |< 28                                                   'EEPROM's SCL pin mask (P28)

{Host Initialized Values (values below are examples only)}                                                                
  BootClkSel    long    $6F & $07                                '[host init]   'Boot loader's clock selection bits (used when switching to target app clock mode)
  BitTime                                                                       'Bit period (in clock cycles)
    IBitTime    long    80_000_000 / 115_200                     '[host init]   '  Initial bit period (at startup)
    FBitTime    long    80_000_000 / 921_600                     '[host init]   '  Final bit period (for download)
  BitTime1_5    long    TRUNC(1.5 * 80_000_000.0 / 921_600.0)    '[host init]   '1.5x bit period; used to align to center of received bits
  Timeout                                                                       'Timeout
    Failsafe    long    2 * 80_000_000 / (3 * 4)                 '[host init]   '  Failsafe timeout (2 seconds worth of Acknowledge:RxWait loop iterations)
    EndOfPacket long    2 * 80_000_000 / 921_600 * 10 * (3 * 4)  '[host init]   '  End of packet timeout (2 bytes worth of Acknowledge:RxWait loop iterations)
  STime         long    trunc(80_000_000.0 * 0.000_000_6) #> 14  '[host init]   'Minimum EEPROM Start/Stop Condition setup/hold time (1/0.6 µs); [Min 14 cycles]
  SCLHighTime   long    trunc(80_000_000.0 * 0.000_000_6) #> 14  '[host init]   'Minimum EEPROM SCL high time (1/0.6 µs); [Min 14 cycles]
  SCLLowTime    long    trunc(80_000_000.0 * 0.000_001_3) #> 26  '[host init]   'Minimum EEPROM SCL low time (1/1.3 µs); [Min 26 cycles]
  ExpectedID    long    0                                        '[host init]   'Expected Packet ID; [For acknowledgements, RcvdTransID must follow!]

{Reserved Variables}
  RcvdTransID                                                                   'Received Transmission ID (for acknowledgements) and
    PacketAddr  res     1                                                       '  PacketAddr (for receiving/copying packets)
  TimeDelay     res     1                                                       'Timout delay
  BitDelay      res     1                                                       'Bit time delay
  SByte         res     1                                                       'Serial Byte; received or to transmit; from/to Wi-Fi or EEPROM
  Longs         res     1                                                       'Long counter
  Bytes         res     1                                                       'Byte counter (or byte value)
  Bits          res     1                                                       'Bits counter
  Packet                                                                        'Packet buffer
    PacketID    res     1                                                       '  Header:  Packet ID number (unique per packet payload)
    TransID     res     1                                                       '  Header:  Transmission ID number (unique per host tranmission)
    PacketData  res     (MaxPayload / 4) - 2                                    '  Payload: Packet data (longs); (max size in longs) - header
  
                                                                                         
'***************************************
'*             Finalization            *
'***************************************

{The following are final booter routines delivered inside packets, as needed.  They are "executable" packets marked with Packet ID's of 0 and lower.} 


'----------------------------------------------------------
'---- Finalize and Verify RAM (Executable Packet Code) ----
'----------------------------------------------------------
                            org     PacketData-1                                'Line up executable packet code
                            long    PacketCode                                  'Mark as executable packet

                            {Entire Application Received; clear remaining RAM}           
  RAMFinalizeVerify         mov     Longs, EndOfRAM                             'Determine number of registers to clear
                            sub     Longs, MemAddr                                       
                            shr     Longs, #2               wz                           
    :Clear    if_nz         wrlong  Zero, MemAddr                               'Clear register
              if_nz         add     MemAddr, #4                                 '  Increment Main RAM address
              if_nz         djnz    Longs, #:Clear                              'Loop until end; Main RAM Addr = $8000
                                                                                         
                            {Insert initial call frame}                                  
                            rdword  Longs, #5<<1                                'Get next stack address
                            sub     Longs, #4                                   'Adjust to previous stack address
                            wrlong  CallFrame, Longs                            'Store initial call frame
                            sub     Longs, #4                                            
                            wrlong  CallFrame, Longs                                     
                                                                                         
                            {Verify RAM; calculate checksum}                    '(Checksum = 0, MemAddr = $8000)
    :Validate               sub     MemAddr, #1                                 'Decrement Main RAM Address
                            rdbyte  Bytes, MemAddr                              '  Read next byte from Main RAM
                            add     Checksum, Bytes                             '  Adjust checksum
                            tjnz    MemAddr, #:Validate                         'Loop for all RAM
                            neg     ExpectedID, Checksum                        'Set ExpectedID to negative checksum; Main RAM Addr = $0000
                            jmp     #Acknowledge                                'ACK=Proper -Checksum, NAK=Improper Checksum

                            
'------------------------------------------------------------
'---- Program and Verify EEPROM (Executable Packet Code) ----
'------------------------------------------------------------
                            org     PacketData-1                                'Line up executable packet code
                            long    PacketCode                                  'Mark as executable packet

                            {RAM programed and verified; Program EEPROM}                 
  EEPROMProgramVerify       shl     Checksum, #3                                'Make Checksum indicate programming/verifying (*8 for now)
                            or      dira, SCLPin                                'Set SCL to output (low); MemAddr = $0000

                            {Program EEPROM}
    :NextPage               call    #EE_StartWrite                              'Begin sequential (page) write
                            mov     Bytes, #$40                                 '  Ready for $40 bytes (per page)
    :NextByte               rdbyte  SByte, MemAddr                              '    Get next RAM byte
                            call    #EE_Transmit                                '      Send byte
                if_c        jmp     #EEFail                                     '      Error? Abort
                            add     MemAddr, #1                                 '      Increment address
                            djnz    Bytes, #:NextByte                           '    Loop for full page
                            call    #EE_Stop                                    '  Initiate page-program cycle
                            cmp     MemAddr, EndOfRAM       wz                  '  Copied all RAM? z=yes
                if_nz       jmp     #:NextPage                                  'Loop until copied all RAM

                            {Verify EEPROM}
                            mov     MemAddr, #$0                                'Reset address
                            mov     Bytes, EndOfRAM                             'Ready for all bytes (full memory)
                            call    #EE_StartRead                               'Begin sequential read
    :CheckNextByte          call    #EE_Receive                                 '  Get next EEPROM byte (into SByte)
                            rdbyte  Bits, MemAddr                               '  Get next RAM byte (into Bits)
                            cmp     Bits, SByte             wz                  '  Are they the same? (z = yes)
                if_nz       jmp     #EEFail                                     '  If not equal, abort
                            add     MemAddr, #1                                 '  Increment address
                            djnz    Bytes, #:CheckNextByte                      'Loop for all bytes

                            {Verified}
                            shr     Checksum, #1                                'Make Checksum indicate program/verify done (*4 for now)

                            {Finish and Acknowledge}
  EEFail                    call    #EE_Stop                                    'Disengage EEPROM
                            shr     Checksum, #1                                'All is well? Make Checksum indicate perfection (*2)
  EEFailNoStop              neg     ExpectedID, Checksum                        'Set ExpectedID to -(modified checksum)
                            jmp     #Acknowledge                                'ACK=-Checksum*2, NAK= Improper -Checksum
                                                                  
                                                                     
                            {Start Sequential Read EEPROM operation.}
                            {Caller need not honor page size.       }
  EE_StartRead              call    #EE_StartWrite                              'Start write operation (to send address)        [Start EEPROM Read]
                            mov     SByte, #$A1                                 'Send read command
                            call    #EE_Start
                if_c        jmp     #EEFail                                     'No ACK?  Abort
  EE_StartRead_ret          ret

  
                            {Start Sequential Write EEPROM operation.}
                            {Caller must honor page size by calling  }
                            {EE_Stop before overflow.                }                          
  EE_StartWrite             mov     Longs, #511                                 '>11ms of EE Ack attempts @80MHz                [Wake EEPROM, Start EEPROM Write]
    :Loop                   mov     SByte, #$A0                                 'Send write command
                            call    #EE_Start
                if_c        djnz    Longs, #:Loop                               'No ACK?  Loop until exhausted attempts
                if_nc       mov     SByte, MemAddr                              'Else ACK; send EEPROM high address
                if_nc       shr     SByte, #8
                if_nc       call    #EE_Transmit
                if_nc       mov     SByte, MemAddr                              'Still ACK? send EEPROM low address
                if_nc       call    #EE_Transmit
                if_c        jmp     #EEFail                                     'No ACK?  Abort
  EE_StartWrite_ret         ret

                                                                               
                            {Start/Stop EEPROM operation.              }        'Legend        AC      A-SCL Low                       
                            {If Start, sends command (in SByte) after. }        '   SCL    B-SDA Float/Low (Prep for Start/Stop)
                            {If Stop, returns immediately when done.   }        '                 D     C-SCL High
                            {                                          }        ' (Start) SDA    D-Sample SDA (1=Ready, 0=Busy)         
                            {Either EE_StartRead or EE_StartWrite must }        '               B│ E│F  E-SDA Low/Float (Start/Stop Condition)           
                            {have been called prior.                   }        '  (Stop) SDA    F-If Stop, sample SDA (1=Ready, 0=Busy)
                            
  EE_Start                  test    Reset, Reset            wz                  'Clear z (create Start Condition)
                            jmp     #$+2                                        'Skip next instruction
  EE_Stop                   testn   Reset, Reset            wz                  'Set z (create Stop Condition)
                            mov     Bits, #9                                    'Ready 9 attempts                               [Start/Stop EEPROM]
    :Loop                   mov     BitDelay, SCLLowTime                        'Prep for SCL Low time
                            add     BitDelay, cnt                               '
                            andn    outa, SCLPin                    '4          '  SCL low
                            muxz    dira, SDAPin                    '4          '  SDA float/low (Start/Stop; z=0/1)
                            waitcnt BitDelay, STime                 '6+!(14+)   '  Wait SCL Low time and prep for Start/Stop Setup time
                            or      outa, SCLPin                    '4          '  SCL high
                            test    SDAPin, ina             wc      '4          '  Sample SDA; c = ready, nc = not ready
                            waitcnt BitDelay, STime                 '6+!(14+)   '  Wait Start/Stop Setup time and prep for Start/Stop Hold time
              if_c_or_z     muxnz   dira, SDAPin                    '4          '  If Start+ready or Stop, SDA low/float (Start/Stop Condition; z=0/1)
              if_c_or_z     waitcnt BitDelay, #0                    '6+!(10+)   '  If Start+ready or Stop, wait Start/Stop Hold time (no prep for next delay)
              if_z          test    SDAPin,ina              wc                  '  If Stop, sample SDA; c = ready, nc = not ready
              if_nc         djnz    Bits, #:Loop                                'If bus busy, loop until exhausted attempts
              if_nc_and_nz  jmp     #EEFail                                     'Bus busy, exhausted attempts, and Start? Abort
              if_nc_and_z   jmp     #EEFailNoStop                               'Bus busy, exhausted attempts, and Stop? Abort without stop condition
  EE_Stop_ret if_z          ret                                                 'If Stop, return; else Start continues below

                        
                            {Transmit to or receive from EEPROM.}               'Legend            1x...9x
                            {On return: c = NAK, nc = ACK.      }               '        AC       A-SCL Low                              
                                                                                '         SCL  ..  B-Output SDA Bit (Float / Low)
                                                                                '               BD        C-SCL High                             
                                                                                ' (Start) SDA  ..  D-Sample SDA in case ACK/NAK (1=NAK, 0=ACK)
                                                                                
  EE_Transmit               shl     SByte, #1                                   'Ready to transmit byte and receive ACK         [Transmit/Receive]
                            or      SByte, #%00000000_1                          
                            jmp     #$+2                                         
  EE_Receive                mov     SByte, #%11111111_0                         'Ready to receive byte and transmit ACK
                            mov     Bits, #9                                    'Set for 9 bits (8 data + 1 ACK (if Tx))
                            mov     BitDelay, SCLLowTime                        'Prep for SCL Low time
                            add     BitDelay, cnt                               '
    :Loop                   andn    outa, SCLPin                    '4          'SCL low
                            test    SByte, #$100            wz      '4           ' Get next SDA output state; z=bit
                            rcl     SByte, #1                       '4           ' Shift in prior SDA input state
                            muxz    dira, SDAPin                    '4           ' Generate SDA state (SDA low/float)
                            waitcnt BitDelay, SCLHighTime           '6+!(22+)[26]' Wait SCL Low time and prep for SCL High time
                            or      outa, SCLPin                    '4           ' SCL high
                            test    SDAPin, ina             wc      '4           ' Sample SDA; c=NAK, nc=ACK
                            waitcnt BitDelay, SCLLowTime            '6+!(14+)    ' Wait SCL High time and prep for SCL Low time
                            djnz    Bits, #:Loop                    '4          'If another bit, loop
                            and     SByte, #$FF                                 'Isolate byte received
  EE_Receive_ret
  EE_Transmit_ret
  EE_Start_ret              ret                                                 'nc = ACK


'***************************************
{Shutdown EEPROM and Propeller pin outputs}
' EE_Shutdown               mov     EE_Jmp, #0                                  'Deselect EEPROM (replace jmp with nop)         [Shutdown EEPROM]
'                           call    #EE_Stop                                    '(always returns)
'                           mov     dira, #0                                    'Cancel any outputs
' EE_Shutdown_ret           ret                                                 'Return


{
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│   Min and Max Specifications for Microchip 24xx256/512 EEPROM @ 2.5 V <= Vcc <= 5.5V.    │
│                                                                                          │
│                              1  2  ├ 3 ┼ 4 ┤                                           │
│                     SCL     ...                      │
│                              │5│6│       │7│8│           │9├ A ┤                         │
│                     SDA IN  ...                      │
│                                                  │B│                                     │
│                     SDA OUT ...                                 │
├──────────────────────────────────┬─────────────────┬┬─────────────────┬┬─────────────────┤
│                                  │  100 KHz Speed  ││  400 KHz Speed  ││   1 MHz Speed   │
│   Event Item and Description     │  Min      Max   ││  Min      Max   ││  Min      Max   │
├──────────────────────────────────┼────────┼────────┼┼────────┼────────┼┼────────┼────────┤
│1 (SCL and SDA Rise Time)         │        │ 1.00 µs││        │ 0.30 µs││        │ 0.30 µs│
├──────────────────────────────────┼────────┼────────┼┼────────┼────────┼┼────────┼────────┤
│2 (SCL and SDA Fall Time)         │        │ 0.30 µs││        │ 0.30 µs││        │ 0.10 µs│
├──────────────────────────────────┼────────┼────────┼┼────────┼────────┼┼────────┼────────┤
│3 (SCL High Period)               │ 4.0 µs │        ││ 0.6 µs │        ││ 0.5 µs │        │
├──────────────────────────────────┼────────┼────────┼┼────────┼────────┼┼────────┼────────┤
│4 (SCL Low Period)                │ 4.7 µs │        ││ 1.3 µs │        ││ 0.5 µs │        │
├──────────────────────────────────┼────────┼────────┼┼────────┼────────┼┼────────┼────────┤
│5 (Start-Condition Setup Time)    │ 4.7 µs │        ││ 0.6 µs │        ││ 0.25 µs│        │
├──────────────────────────────────┼────────┼────────┼┼────────┼────────┼┼────────┼────────┤
│6 (Start-Condition Hold Time)     │ 4.0 µs │        ││ 0.6 µs │        ││ 0.25 µs│        │
├──────────────────────────────────┼────────┼────────┼┼────────┼────────┼┼────────┼────────┤
│7 (Data Hold Time)                │  0 µs  │        ││  0 µs  │        ││  0 µs  │        │
├──────────────────────────────────┼────────┼────────┼┼────────┼────────┼┼────────┼────────┤
│8 (Data Setup Time)               │ 0.25 µs│        ││ 0.1 µs │        ││ 0.1 µs │        │
├──────────────────────────────────┼────────┼────────┼┼────────┼────────┼┼────────┼────────┤
│9 (Stop-Condition Setup Time)     │ 4.0 µs │        ││ 0.6 µs │        ││ 0.25 µs│        │
├──────────────────────────────────┼────────┼────────┼┼────────┼────────┼┼────────┼────────┤
│A (Time Between Stop/Start-Cond's)│ 4.7 µs │        ││ 1.3 µs │        ││ 0.5 µs │        │
├──────────────────────────────────┼────────┼────────┼┼────────┼────────┼┼────────┼────────┤
│B (SCL low to SDA Data Out)       │        │ 3.5 µs ││        │ 0.9 µs ││        │ 0.4 µs │
└──────────────────────────────────┴────────┴────────┴┴────────┴────────┴┴────────┴────────┘
}       


'-----------------------------------------------------------------
'---- Prep for Validation and Launch (Executable Packet Code) ----
'-----------------------------------------------------------------

{The following two routines are "launch" packets; together they form a ready-to-launch and launch-now command sequence.  Without this two-stage launch
command sequence, network packet loss can leave the host or Propeller without positive knowledge that they are successful and that the launch will occur.

To ensure launch, the ready-to-launch packet injects launch code into the booter's timeout sequence- in case the launch-now packet is never received.  Then
it sends positive acknowledgement of itself to the host- this notifies the host that the Propeller knows it must launch.  Then the host sends the launch-now
packet- this notifies the Propeller that it's time to launch now and the Propeller does so immediately without any more acknowledgement to the host.

Up to (but not including) the launch-now packet, the host and Propeller advance through the protocol only with definitive, positive acknowledgement of each
packet's delivery- repeating/requesting packet transmissions if necessary.  The ready-to-launch packet is the last packet that is actively acknowledged.

If the launch-now packet is not received, the booter times out and executes the :LaunchCode automatically, knowing that the host knows the ready-to-launch
command was received. This rare case results in a little delay but not a failure to launch or failure to notify the user of success.

Launch Clock Setting: When launching the target application, :LaunchCode must first switch to the target's clock settings.  The booter is already running
with an external clock source, so the oscillator feedback circuit is active, but the PLL circuit may need enabling.  For safety, it uses a two-step clock
switch process to provide a short delay for PLL stabilization.}


                            org     PacketData-1                                'Line up executable packet code
                            long    PacketCode                                  'Mark as executable packet
                
  ReadyToLaunch             movi    TOVector, #JMP_Inst                         'We can safely launch upon timeout now; replace timeout vector's 
                            movs    TOVector, #:LaunchCode                      'restart instruction with a jump to :LaunchCode, below
                            jmp     #Acknowledge                                'Jump (pass 1) to send acknowledgement
                            
    :LaunchCode             rdword  Bytes, #3<<1                                'Else (pass 2 or LaunchNow-activated), get program base address
                            cmp     Bytes, #$0010           wz                  'Is program base valid? nz=Invalid
              if_nz         clkset  Reset                                       'Invalid?  Reset Propeller
                            rdbyte  Bytes, #4                                   'Get target app's clock mode, preserve PLL/OSC and add booter's CLKSEL
                            and     Bytes, #$78                                 
                            or      Bytes, BootClkSel                           
                            clkset  Bytes                                       'Switch to target's clock PLL/OSC mode (but with current CLKSEL mode)
                            shl     SCLHighTime, #64                            'Prep for brief delay (spec. SCL High must be >= 0.391 µS)
    :SettlePLL              djnz    SCLHighTime, #:SettlePLL        '4/8        'Wait > 100 uS in case PLL needs to settle
                            rdbyte  Bytes,#4                                    'Switch to target's full clock mode setting
                            clkset  Bytes
                            coginit interpreter                                 'Relaunch with Spin Interpreter

                            
'------------------------------------------------------
'---- Validate and Launch (Executable Packet Code) ----
'------------------------------------------------------

{The following routine may never be received due to packet loss.  This is an acceptable "soft" error.  If this routine isn't received, the booter will
timeout and execute :LaunchCode from the previous packet anyway.}

                            org     PacketData-1                                'Line up executable packet code
                            long    PacketCode                                  'Mark as executable packet
                
  LaunchNow                 jmp     #LaunchNow+3 {#:LaunchCode}                 'Execute previous packet's :LaunchCode
                            