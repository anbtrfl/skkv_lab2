enum {C1_NOP, C1_READ8, C1_READ16, C1_READ32, C1_INVALIDATE_LINE, C1_WRITE8, C1_WRITE16, C1_WRITE32} C1_ASK;   //команды процессор->кэш
enum {C1_NOP2, C1_RESPONSE = 7} C1_ANSWER;                                                                     //команды кэш->процессор
enum {C2_NOP, C2_RESPONSE, C2_READ_LINE, C2_WRITE_LINE} C2_B;                                                  //команды кэш<->память

parameter MEM_SIZE = 524288;        //размер памяти
parameter CACHE_SIZE = 1024;        //размер кэша
parameter CACHE_LINE_SIZE = 16;     //размер кэш-линии
parameter CACHE_LINE_COUNT = 64;    //кол-во кэш-линий
parameter CACHE_WAY = 2;            //ассоциативность
parameter CACHE_SETS_COUNT = 32;    //кол-во наборов кэш-линий
parameter CACHE_TAG_SIZE = 10;      //размер тэга адреса
parameter CACHE_SET_SIZE = 5;       //размер индекса в наборе кэш-линий
parameter CACHE_OFFSET_SIZE = 4;    //размер смещения
parameter CACHE_ADDR_SIZE = 19;     //размер адреса

parameter ADDR1_BUS_SIZE = CACHE_TAG_SIZE+CACHE_SET_SIZE;   // ширина шины A1
parameter ADDR2_BUS_SIZE = CACHE_TAG_SIZE+CACHE_SET_SIZE;   // ширина шины A2
parameter DATA1_BUS_SIZE = 16;                              // ширина шины D1
parameter DATA2_BUS_SIZE = 16;                              // ширина шины D2
parameter CTR1_BUS_SIZE = 3;                                // ширина шины C1
parameter CTR2_BUS_SIZE = 2;                                // ширина шины C2

module MemCTR (
    input CLK,                      //вход синхронизации
	input RESET,                    //вход сброса
	input [ADDR2_BUS_SIZE-1:0] A2,	//шина А2
	inout [DATA2_BUS_SIZE-1:0] D2,           //шина D2
	inout [CTR2_BUS_SIZE-1:0] CTR2,          //шина C2
	input M_DUMP                    //сигнал сохранения состояния памяти
 );

reg [7:0] Mem [MEM_SIZE-1:0];

integer SEED = 225526;
integer i = 0;
  initial begin    
    for (i = 0; i < MEM_SIZE; i += 1) begin
      Mem[i] = $random(SEED)>>16;  
    end
   
    for (i = 0; i < MEM_SIZE; i += 1) begin
      $display("[%d] %d", i, Mem[i]);  
    end
   
//    $finish;
  end 
endmodule;

module Cache (
    input CLK,                      //вход синхронизации
	input RESET,                    //вход сброса
	input [ADDR1_BUS_SIZE-1:0] A1,	//шина А1
	output [ADDR2_BUS_SIZE-1:0] A2,	//шина А2
	inout [DATA1_BUS_SIZE-1:0] D1,           //шина D1
	inout [DATA2_BUS_SIZE-1:0] D2,           //шина D2
	inout [CTR1_BUS_SIZE-1:0] CTR1,          //шина C1
	inout [CTR2_BUS_SIZE-1:0] CTR2,          //шина C2
	input C_DUMP                    //сигнал сохранения состояния кэша
 );

localparam RS_Idle = 0;
localparam RS_Read2nd = 1;
localparam RS_Wait = 2;
//localparam RS_WriteWait = 3;
localparam RS_RDLogic = 4;
localparam RS_RDAnswer = 5;
localparam RS_RDAnswer2nd = 6;
localparam RS_WriteLine = 7;
localparam RS_WriteLineData = 8;
localparam RS_WaitMem = 9;
localparam RS_ReadLine = 10;
localparam RS_ReadWait = 11;
localparam RS_ReadLineData = 12;
localparam RS_Invalidate = 21;

integer ICount = 0, LCount = 0;

reg [CACHE_LINE_SIZE-1:0] DataSet0 [0:CACHE_SETS_COUNT-1];
reg [CACHE_LINE_SIZE-1:0] DataSet1 [0:CACHE_SETS_COUNT-1];
reg [CACHE_TAG_SIZE-1:0] TagSet0 [0:CACHE_SETS_COUNT-1];
reg [CACHE_TAG_SIZE-1:0] TagSet1 [0:CACHE_SETS_COUNT-1];
reg Valid0 [0:CACHE_SETS_COUNT-1];
reg Valid1 [0:CACHE_SETS_COUNT-1];
reg Dirty0 [0:CACHE_SETS_COUNT-1];
reg Dirty1 [0:CACHE_SETS_COUNT-1];
reg ToFree [0:CACHE_SETS_COUNT-1];

reg [CACHE_TAG_SIZE-1:0] ctag,A2tag;
reg [CACHE_SET_SIZE-1:0] cset;
reg [CACHE_OFFSET_SIZE-1:0] coffset;

reg	[DATA1_BUS_SIZE-1:0] answer_word; 
reg	[CTR1_BUS_SIZE-1:0] answer_cmd; 
reg	[DATA2_BUS_SIZE-1:0] mem_word; 
reg	[CTR2_BUS_SIZE-1:0] mem_cmd,mem_answer; 

reg [CACHE_LINE_SIZE-1:0] ActLine;
reg ReadToSet;


reg D1Ctrl; // 1 - управлять шинами D1 CTR1 0 - не управлять
reg D2Ctrl; // 1 - управлять шинами D2 CTR2 0 - не управлять

wire hit0,hit1,hit;

assign hit0 = (TagSet0[cset]==ctag)&&Valid0[cset];
assign hit1 = (TagSet1[cset]==ctag)&&Valid1[cset];
assign hit = hit0 | hit1;

assign D1 = (D1Ctrl) ? answer_word : 16'dZ; 
assign CTR1 = (D1Ctrl) ? answer_cmd : 3'dZ; 
assign D2 = (D2Ctrl) ? mem_word : 16'dZ; 
assign CTR2 = (D2Ctrl) ? mem_cmd : 2'dZ; 
assign A2=(A2tag<<CACHE_SET_SIZE)|cset;

reg [5:0] IState,NewState,RetState; // IState - внутреннее состояние. NewState - состояние в которое перейти по окончанию ожидания. RetState - состояние в которое вернуться после записи строки в память.
reg [CTR1_BUS_SIZE-1:0] cmd;

integer i = 0;
  initial begin    
    IState = RS_Idle;
	D1Ctrl='b0;
	for (i = 0; i < CACHE_LINE_COUNT; i += 1) begin
		Valid0[i]=0;
		Valid1[i]=0;
		Dirty0[i]=0;
		Dirty1[i]=0;
	end;
  end;	

always@(posedge CLK or posedge RESET or posedge C_DUMP)
begin
	if(RESET)
	begin
    IState = RS_Idle;
	D1Ctrl='b0;
	for (i = 0; i < CACHE_LINE_COUNT; i += 1) begin
		Valid0[i]=0;
		Valid1[i]=0;
		Dirty0[i]=0;
		Dirty1[i]=0;
	end;
	end
	else if (C_DUMP) begin
     for (i = 0; i < CACHE_LINE_COUNT; i += 1) begin
       $display("Line [%d]: ToDel=%b; Set0: Valid=%b Dirty=%b Tag=%h Data=%h; Set1: Valid=%b Dirty=%b Tag=%h Data=%h;", i, ToFree[i], Valid0[i], Dirty0[i], TagSet0[i], DataSet0[i], Valid1[i], Dirty1[i], TagSet1[i], DataSet1[i]);  
     end

	end
	else begin 	
		case(IState)//а это тот самый автомат состояний IState = текущее состояние
		RS_Idle:begin
			case(CTR1)
			C1_INVALIDATE_LINE:begin
				ctag=A1[14:5];
				cset=A1[4:0];
				ICount=5;
				IState=RS_Wait;
				NewState=RS_Invalidate;
			end
			C1_READ8,C1_READ16,C1_READ32:begin
				ctag=A1[14:5];
				cset=A1[4:0];
				IState=RS_Read2nd;
				cmd=CTR1;
			end
			endcase
		end
		RS_Invalidate:begin
			D1Ctrl='b1;
			answer_word=0;
			D1Ctrl<='b0;
			answer_cmd=C1_RESPONSE;
			if (hit0) Valid0[cset]=0;
			if (hit1) Valid1[cset]=0;
			IState=RS_Idle;
		end
		RS_Read2nd: begin
			coffset=A1[4:0];
			IState=RS_RDLogic;
			D1Ctrl='b1;
			answer_cmd=C1_NOP;
			answer_word='d0;
			end
		RS_RDLogic: begin
			if (hit==1'd1) begin
				ICount=3; // прошло два такта, пропустить еще 3 до ответа
				IState=RS_Wait;
				NewState=RS_RDAnswer;
				ToFree[cset]=hit0; //кого выкидывать при промахе
			end
			else begin //промах - надо читать память
			  if (ToFree[cset]==1'b0) begin //выбрасываем линию из set0
				if ((Valid0[cset]&&Dirty0[cset])==1'b1) begin
				//линия валидна и грязная - сохранить линию в память
					A2tag=TagSet0[cset];
					ActLine=DataSet0[cset];
					ICount=1; // пропустить такт до работы с памятью по условиям 4й
					IState=RS_Wait; 
					NewState=RS_WriteLine;
					ReadToSet=0;
					RetState=RS_RDLogic; //после записи опять вернемся в это состояние
			       end
				else begin
					//линию можно выбросить и читать новую из памяти
					A2tag=ctag;
					ICount=1; // пропустить такт до работы с памятью по условиям 4й
					IState=RS_Wait; 
					NewState=RS_ReadLine;
					ReadToSet=0;
					RetState=RS_RDLogic; //после чтения опять вернемся в это состояние
				end
			  end
			  else begin
			  
				if ((Valid1[cset]&Dirty1[cset])==1'b1) begin
				//линия валидна и грязная - сохранить линию в память
					A2tag=TagSet1[cset];
					ActLine=DataSet1[cset];
					ICount=1; // пропустить такт до работы с памятью по условиям 4й
					IState=RS_Wait; 
					NewState=RS_WriteLine;
					ReadToSet=1;
					RetState=RS_RDLogic; //после записи опять вернемся в это состояние
			       end
				else begin
					//линию можно выбросить и читать новую из памяти
					A2tag=ctag;
					ICount=1; // пропустить такт до работы с памятью по условиям 4й
					IState=RS_Wait; 
					NewState=RS_ReadLine;
					ReadToSet=1;
					RetState=RS_RDLogic; //после чтения опять вернемся в это состояние
				end
			  end
		   end
		end
		RS_WriteLine:begin 
			mem_word=ActLine[15:0];
			mem_cmd=C2_WRITE_LINE;
			D2Ctrl=1;
     		LCount=(CACHE_LINE_SIZE/DATA2_BUS_SIZE);
		end
		RS_WriteLineData:begin
			ActLine>>=16;
			mem_word=ActLine[15:0];
     		LCount-=1;
			if (LCount==0) begin
				//кончилась линия
				D2Ctrl<=0;
				IState=RS_WaitMem;
			end
		end
		RS_WaitMem:begin
			if (CTR2==C2_RESPONSE) begin
					if (ReadToSet==0) Dirty0[cset]=0; //сбрасываем Dirty
								 else Dirty1[cset]=0;
				IState=RetState;
				mem_cmd=C2_NOP;
				D2Ctrl=1;
			end
		end
		RS_ReadLine:begin
			mem_cmd=C2_READ_LINE;
			D2Ctrl=1;
     		LCount=(CACHE_LINE_SIZE/DATA2_BUS_SIZE);
		end
		RS_ReadWait:begin
			D2Ctrl=0;
			IState=RS_ReadLineData;
		end
		RS_ReadLineData:begin
			if (CTR2==C2_RESPONSE) begin
				ActLine<<=16;
				ActLine=ActLine|D2;
				LCount-=1;
    			if (LCount==0) begin
				//прочитали всю линию
					if (ReadToSet==0) begin // Линия валидная и чистая
						DataSet0[cset]=ActLine;
						TagSet0[cset]=ctag;
						Valid0[cset]=1; 
						Dirty0[cset]=0;
					end
					else begin
						DataSet1[cset]=ActLine;
						TagSet0[cset]=ctag;
						Valid1[cset]=1;
						Dirty1[cset]=0;
					end
		    		IState=RetState;
   				    mem_cmd=C2_NOP;
				    D2Ctrl=1;
			    	end
			end
		end
		RS_Wait:begin
			ICount-=1;
			if (ICount==0) IState=NewState;
		end
		RS_RDAnswer: begin
		    answer_cmd=C1_RESPONSE;
			case (cmd)
			   C1_READ8:begin
				  answer_word[15:8]=8'd0;
				  if (hit0) answer_word[7:0]=DataSet0[cset][coffset];
				  else answer_word[7:0]=DataSet1[cset][coffset];
 			  	  IState=RS_Idle;
				  D1Ctrl<=0;
				 end
				   C1_READ16:begin
					  if (hit0) begin
						 answer_word[7:0]=DataSet0[cset][coffset];
						 answer_word[15:8]=DataSet0[cset][coffset+1];
					  end
					  else begin
						answer_word[7:0]=DataSet1[cset][coffset];
  					    answer_word[15:8]=DataSet1[cset][coffset+1];
					  end
					  IState=RS_Idle;
					  D1Ctrl<=0;
				   end
				   C1_READ32:begin
					  if (hit0) begin
						 answer_word[7:0]=DataSet0[cset][coffset];
						 answer_word[15:8]=DataSet0[cset][coffset+1];
					  end
					  else begin
						answer_word[7:0]=DataSet1[cset][coffset];
  					    answer_word[15:8]=DataSet1[cset][coffset+1];
					  end
					  IState=RS_RDAnswer2nd;
				   end
				endcase;
		end
		RS_RDAnswer2nd: begin
					  if (hit0) begin
						 answer_word[7:0]=DataSet0[cset][coffset+2];
						 answer_word[15:8]=DataSet0[cset][coffset+2];
					  end
					  else begin
						answer_word[7:0]=DataSet1[cset][coffset+2];
  					    answer_word[15:8]=DataSet1[cset][coffset+3];
					  end
					  IState=RS_Idle;
					  D1Ctrl<=0;
		end
		endcase
	end
end

endmodule;

module CPU  (
    input CLK,                      //вход синхронизации
	output [ADDR1_BUS_SIZE-1:0] A1,	//шина А1
	inout [DATA1_BUS_SIZE-1:0] D1,           //шина D1
	inout [CTR1_BUS_SIZE-1:0] CTR1          //шина C1
 );
endmodule;
