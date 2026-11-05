# Copyright (C) 2026 Kevin Zheng
# SPDX-License-Identifier: GPL-3.0-only
"""Loopback-only SNMPv2c fixture, no real NAS or credentials. Test harness only."""
import socket,sys

def tlv(tag,data):
    n=len(data)
    length=bytes([n]) if n<128 else bytes([0x82])+n.to_bytes(2,'big')
    return bytes([tag])+length+data

def parse(data,start=0):
    tag,n=data[start:start+2];p=start+2
    if n&128:
        count=n&127;n=int.from_bytes(data[p:p+count],'big');p+=count
    return tag,data[p:p+n],p+n

def parts(data):
    out=[];p=0
    while p<len(data):
        t,v,p=parse(data,p);out.append((t,v))
    return out

def integer(n):
    raw=n.to_bytes(max(1,(n.bit_length()+8)//8),'big',signed=True)
    return tlv(2,raw)

def oid_numbers(raw):
    result=[raw[0]//40,raw[0]%40];n=0
    for b in raw[1:]:
        n=(n<<7)|(b&127)
        if not b&128:result.append(n);n=0
    return '.'.join(map(str,result))

def encode_oid(key):
    nums=list(map(int,key.split('.')));raw=bytes([nums[0]*40+nums[1]])
    for n in nums[2:]:
        b=[n&127];n>>=7
        while n:b.insert(0,(n&127)|128);n>>=7
        raw+=bytes(b)
    return raw

smbroot='1.3.6.1.4.1.6574.111'
smb={}
for table,count in [(1,1),(2,19),(3,12)]:
    for column in [2,3,4]:
        for index in range(1,count+1):
            key=f'{smbroot}.{table}.1.{column}.{index}'
            smb[key]=tlv(4,f'metric_{table}_{index}'.encode()) if column==2 else integer(2000 if column==4 else 10)

ipv6='--ipv6' in sys.argv
tcp='--tcp' in sys.argv
sock=socket.socket(socket.AF_INET6 if ipv6 else socket.AF_INET,socket.SOCK_STREAM if tcp else socket.SOCK_DGRAM);sock.bind(('::1' if ipv6 else '127.0.0.1',0))
if tcp:sock.listen(1)
print(sock.getsockname()[1],flush=True)
connection=None
def exact(n):
    b=b''
    while len(b)<n:
        part=connection.recv(n-len(b))
        if not part:raise EOFError()
        b+=part
    return b
def receive():
    global connection
    if not tcp:return sock.recvfrom(65535)
    while True:
        if connection is None:connection,_=sock.accept()
        try:
            head=exact(2);n=head[1]
            if n&128:
                length=exact(n&127);head+=length;n=int.from_bytes(length,'big')
            return head+exact(n),None
        except EOFError:
            connection.close();connection=None

def reply_to(data,peer):
    if tcp:
        # Split the BER header deliberately: TCP is a byte stream.
        connection.sendall(data[:1]);connection.sendall(data[1:])
    else:sock.sendto(data,peer)
cpu_sample=0
while True:
    data,peer=receive()
    if '--drop' in sys.argv: continue
    if '--malformed' in sys.argv:
        reply_to(b'not-a-valid-snmp-packet',peer);continue
    try:
        outer=parts(parse(data)[1]);request=parts(outer[2][1]);bindings=parts(request[3][1]);out=[]
        for _,binding in bindings:
            identifier=parts(binding)[0][1];key=oid_numbers(identifier)
            if key.startswith(smbroot) and outer[2][0]==0xa5:
                candidates=sorted((k for k in smb if tuple(map(int,k.split('.')))>tuple(map(int,key.split('.')))),key=lambda k:tuple(map(int,k.split('.'))))
                # Short pages deliberately: a short page must not end a walk.
                for k in candidates[:17]:out.append(tlv(0x30,tlv(6,encode_oid(k))+smb[k]))
                if not candidates:out.append(tlv(0x30,tlv(6,identifier)+tlv(0x82,b'')))
                continue
            if key=='1.3.6.1.4.1.2021.11' and outer[2][0]==0xa5:
                cpu_sample+=1
                # Subtree prefix BER: append scalar identifier and instance zero.
                for index,ticks in [(50,20),(51,0),(52,10),(53,70),(54,900),(56,0),(61,0),(64,0)]:
                    out.append(tlv(0x30,tlv(6,identifier+bytes([index,0]))+integer(cpu_sample*ticks)))
                continue
            mapping={'1.3.6.1.4.1.6574.1.5.1.0':tlv(4,b'DS923+'),
                     '1.3.6.1.4.1.6574.1.5.3.0':tlv(4,b'DSM 7.3-86009'),
                     '1.3.6.1.4.1.2021.11.11.0':integer(80),
                     '1.3.6.1.4.1.6574.111.2.1.4.14':integer(2000),
                     '1.3.6.1.4.1.6574.111.2.1.3.14':integer(10)}
            if '--identity' in sys.argv and outer[2][0]==0xa5 and key=='1.3.6.1.2.1.4.20.1.1':
                # GETBULK: append the four IPv4 index octets, BER base-128 encoded.
                identifier += bytes([0x81,0x40,0x81,0x28,120,2])
                value=tlv(0x40,bytes([192,168,120,2]))
            else:
                value=mapping.get(key,tlv(0x80,b''))
            out.append(tlv(0x30,tlv(6,identifier)+value))
        reply=tlv(0x30,tlv(2,outer[0][1])+tlv(4,outer[1][1])+tlv(0xa2,tlv(2,request[0][1])+integer(0)+integer(0)+tlv(0x30,b''.join(out))))
        reply_to(reply,peer)
    except Exception as error: print(type(error).__name__,file=sys.stderr,flush=True)
