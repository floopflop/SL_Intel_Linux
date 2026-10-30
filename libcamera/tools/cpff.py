#!/usr/bin/python3 -I
"""Walk an Intel CPFF tuning container (.aiqb/.cpf) and list its sections and records.
Layout (as documented publicly for the IPU6 ia_imaging headers): 4-char tag + u32 size
sections; the L??? section nests DFLT > AIQB; AIQB = 24-byte ia_mkn_header followed by
8-byte record headers {u32 size; u8 fmt; u8 key; u16 name_id}, records 8-byte aligned."""
import struct, sys
NAMES={1:'comment',2:'general_data',3:'black_level',5:'saturation_level',7:'module_sensitivity',
 9:'noise',10:'lens_shading',13:'optics_and_mechanics',15:'chromaticity_response',17:'nvm_info',
 18:'color_matrices',19:'analog_gain_conversion',20:'digital_gain',21:'sensor_metadata',
 23:'exposure_range',25:'advanced_color_matrices',26:'hdr',28:'lens_shading_4x4',
 31:'black_level_global',32:'valid_image_area',33:'lens_shading_4x4_ratio',34:'multi_gain_conversions',
 35:'pipe_comp_decomp',36:'sensor_decomp',37:'media_format',38:'cbd'}
def walk(buf):
    total,=struct.unpack_from('<I',buf,4); o=0x18
    while o+8<=min(total,len(buf)):
        tag=buf[o:o+4].decode('ascii','replace'); size,=struct.unpack_from('<I',buf,o+4)
        if not tag.isalpha() or size<8: break
        yield tag,o,size; o+=size
def records(buf,aiqb):
    hdr,=struct.unpack_from('<I',buf,aiqb+4); end=min(aiqb+hdr,len(buf)); o=aiqb+24
    while o+8<=end:
        size,fmt,key,name=struct.unpack_from('<IBBH',buf,o)
        if size<8 or o+size>end: break
        yield o,size,fmt,key,name; o+=(size+7)&~7
if __name__=='__main__':
    buf=open(sys.argv[1],'rb').read(); want=sys.argv[2] if len(sys.argv)>2 else None
    print(f"{len(buf)} bytes, magic {buf[:4]}")
    for tag,off,size in walk(buf):
        print(f"== {tag} @0x{off:x} size {size}  inner tags: {buf[off+16:off+20]} {buf[off+32:off+36]}")
        aiqb=off+32
        if buf[aiqb:aiqb+4]!=b'AIQB': continue
        for ro,rs,fmt,key,name in records(buf,aiqb):
            label=NAMES.get(name,f'id{name}')
            print(f"   @0x{ro:06x} size {rs:7d} fmt {fmt} key {key} {label}")
            if want and label==want:
                d=buf[ro+8:ro+rs]
                print("      hex:", d[:96].hex(' '))
                print("      u16:", list(struct.unpack_from(f'<{min(len(d)//2,40)}H',d)))
                print("      u32:", list(struct.unpack_from(f'<{min(len(d)//4,20)}I',d)))
