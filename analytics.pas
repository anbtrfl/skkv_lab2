program project1;

type cacheline=record
    tag:array[0..1]of integer;
    valid:array[0..1]of boolean;
    dirty:array[0..1]of boolean;
    todel:integer;
  end;

var
  tactcount,hitcount,accesscount:Int64;
  pa,pb,pc:integer;
  cache:array[0..31]of cacheline;
  i,y,x,k:integer;

const abeg=0;bbeg=2048;cbeg=5888;
      M=64;N=60;KK=32;

procedure mread(addr,plen:integer);
var csetln,ctag,hitset:integer;
  hit:boolean;
begin
     accesscount:=accesscount+1;
     csetln:=(addr shr 4) and $1F;
     ctag:=addr shr 9;
     hitset:=5;
     if cache[csetln].tag[0]=ctag then hitset:=0;
     if cache[csetln].tag[1]=ctag then hitset:=1;
     hit:=(hitset<5);
     if (hit) then begin
        cache[csetln].todel:=hitset xor 1;
        hitcount:=hitcount+1;
        tactcount:=tactcount+7;
        if plen>2 then tactcount:=tactcount+1;
        exit;
        end;
     hitset:=cache[csetln].todel;
     if (cache[csetln].valid[hitset] and cache[csetln].dirty[hitset]) then begin
        cache[csetln].dirty[hitset]:=false;
        cache[csetln].tag[hitset]:=ctag;
        cache[csetln].todel:=hitset xor 1;
        tactcount:=tactcount+5+100+100+8;
        if plen>2 then tactcount:=tactcount+1;
        exit;
        end;
     cache[csetln].valid[hitset]:=true;
     cache[csetln].tag[hitset]:=ctag;
     cache[csetln].todel:=hitset xor 1;
     tactcount:=tactcount+5+100+8;
     if plen>2 then tactcount:=tactcount+1;
end;

procedure mwrite(addr,plen:integer);
var csetln,ctag,hitset:integer;
  hit:boolean;
begin
     accesscount:=accesscount+1;
     csetln:=(addr shr 4) and $1F;
     ctag:=addr shr 9;
     hitset:=5;
     if cache[csetln].tag[0]=ctag then hitset:=0;
     if cache[csetln].tag[1]=ctag then hitset:=1;
     hit:=(hitset<5);


     if (hit) then begin
        cache[csetln].todel:=hitset xor 1;
        cache[csetln].dirty[hitset]:=true;
        hitcount:=hitcount+1;
        tactcount:=tactcount+7;
        exit;
        end;
     hitset:=cache[csetln].todel;
     cache[csetln].dirty[hitset]:=true;
     if (cache[csetln].valid[hitset] and cache[csetln].dirty[hitset]) then begin
        cache[csetln].tag[hitset]:=ctag;
        cache[csetln].todel:=hitset xor 1;
        tactcount:=tactcount+5+100+100+8;
        exit;
        end;
     cache[csetln].valid[hitset]:=true;
     cache[csetln].tag[hitset]:=ctag;
     cache[csetln].todel:=hitset xor 1;
     tactcount:=tactcount+5+100+8;
end;

begin
  tactcount:=4; //три инициалиции pa,pc,y и выход
  hitcount:=0;
  accesscount:=0;

  for i:=0 to 31 do begin
    cache[i].valid[0]:=false;
    cache[i].valid[1]:=false;
    cache[i].todel:=0;
  end;

  pa:=abeg;pc:=cbeg;
  for y:=0 to M-1 do begin
      tactcount:=tactcount+5; // инициализация х; у++, увеличение ра и рс; условный переход на новую итерацию
      for x:=0 to N-1 do begin
          tactcount:=tactcount+5; // инициализация pb, s, k; x++ ; условный переход на новую итерацию
          pb:=bbeg;
          for k:=0 to KK-1 do begin
              tactcount:=tactcount+5; // k++;сложение; увеличение pb; умножение(5) ; условный переход на новую итерацию
              mread(pa+k,1);
              mread(pb+x,2);
              pb:=pb+N;
              end;
          mwrite(pc+x,4);
          end;
      pa:=pa+KK;
      pc:=pc+N;
      end;
   writeln('tacts=',tactcount);
   writeln('hitcount=',hitcount,' accesscount=',accesscount);
   writelnformat('hitrate={0:f3}%',hitcount/accesscount*100);
   readln;
end.
