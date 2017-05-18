import Zlib
import Glibc

let DEFAULT_CHUNK_SIZE:Int = 1 << 16
let PNG_SIGNATURE:[UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]

typealias FilePointer = UnsafeMutablePointer<FILE>

public
enum PNGReadError:Error
{
    case FileError(String),
         FiletypeError,
         IncompleteChunkError,
         UnexpectedCriticalChunkError(String),
         PNGSyntaxError(String),
         DataCorruptionError(String),

         IllegalChunkError(PNGChunk),
         DuplicateChunkError(PNGChunk),
         ChunkOrderingError(PNGChunk),
         MissingHeaderError,
         MissingPalatteError,
         PrematureEOSError,
         PrematureIENDError,

         InterlaceDimensionError
}

public
enum PNGWriteError:Error
{
    case FileWriteError,
         DimemsionError
}

public
enum PNGDecompressionError:Error
{
    case StreamError
    case MissingDictionaryError
    case DataError
    case MemoryError
}

public
enum PNGCompressionError:Error
{
    case StreamError
}

public
struct RGBA<Pixel:UnsignedInteger>:Equatable, CustomStringConvertible
{
    public
    let r:Pixel,
        g:Pixel,
        b:Pixel,
        a:Pixel

    public
    var description:String
    {
        return "(\(self.r), \(self.g), \(self.b), \(self.a))"
    }

    public
    init(_ r:Pixel, _ g:Pixel, _ b:Pixel, _ a:Pixel)
    {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    func with_alpha(_ a:Pixel) -> RGBA<Pixel>
    {
        return RGBA(self.r, self.g, self.b, a)
    }

    func compare_opaque(_ v:Pixel) -> Bool
    {
        return self.r == v && self.g == v && self.b == v
    }

    func compare_opaque(_ r:Pixel, _ g:Pixel, _ b:Pixel) -> Bool
    {
        return self.r == r && self.g == g && self.b == b
    }

    public static
    func == (_ lhs:RGBA<Pixel>, _ rhs:RGBA<Pixel>) -> Bool
    {
        return lhs.r == rhs.r && lhs.g == rhs.g && lhs.b == rhs.b && lhs.a == rhs.a
    }
}

public
enum PNGChunk:String
{
    case __FIRST__,
         IHDR,
         PLTE,
         IDAT,
         IEND,

         cHRM,
         gAMA,
         iCCP,
         sBIT,
         sRGB,
         bKGD,
         hIST,
         tRNS,
         pHYs,
         sPLT,
         tIME,
         iTXt,
         tEXt,
         zTXt,

         PRIVATE,

         __INTERRUPTOR__

    init?(buffer:[UInt8])
    {
        self.init(rawValue: String(buffer.flatMap(UnicodeScalar.init).map(Character.init)))
    }
}

func posix_path(_ path:String) -> String
{
    guard let first_char:Character = path.characters.first
    else
    {
        return path
    }
    var expanded_path:String = path
    if first_char == "~"
    {
        if expanded_path.characters.count == 1 || expanded_path[expanded_path.index(expanded_path.startIndex, offsetBy: 1)] == "/"
        {
            expanded_path = String(cString: getenv("HOME")) + String(expanded_path.characters.dropFirst())
        }
    }
    return expanded_path
}

func quad_byte_to_uint32(_ buffer:[UInt8]) -> UInt32
{
    return UInt32(bigEndian: buffer.withUnsafeBufferPointer
    {
        ($0.baseAddress!.withMemoryRebound(to: UInt32.self, capacity: 1) { $0.pointee })
    })
}

func uint32_to_quad_byte(_ integer:UInt32) -> [UInt8]
{
    return [UInt8(integer >> 24 & 0xFF),
            UInt8(integer >> 16 & 0xFF),
            UInt8(integer >> 8  & 0xFF),
            UInt8(integer       & 0xFF)]
}

func paeth(_ a:UInt8, _ b:UInt8, _ c:UInt8) -> UInt8
{
    let a16 = Int16(a),
        b16 = Int16(b),
        c16 = Int16(c)
    let p:Int16 = a16 + b16 - c16
    let pa = abs(p - a16),
        pb = abs(p - b16),
        pc = abs(p - c16)

    if pa <= pb && pa <= pc
    {
        return a
    }
    else
    {
        return pb <= pc ? b : c
    }
}

struct Header
{
    typealias ColorType = PNGProperties.ColorType

    let width:Int,
        height:Int,
        bit_depth:Int,
        color:ColorType,
        interlaced:Bool

    init(width:Int, height:Int, bit_depth:Int, color:ColorType, interlaced:Bool) throws
    {
        // validate color type
        let allowed_bit_depths:[Int]
        switch color
        {
        case .grayscale_a, .rgb, .rgba:
            allowed_bit_depths = [8, 16]
        case .indexed:
            allowed_bit_depths = [1, 2, 4, 8]
        case .grayscale:
            allowed_bit_depths = [1, 2, 4, 8, 16]
        }
        guard allowed_bit_depths.contains(bit_depth)
        else
        {
            throw PNGReadError.PNGSyntaxError("Color type '\(color)' cannot have a bit depth of \(bit_depth)")
        }

        self.width      = width
        self.height     = height
        self.bit_depth  = bit_depth
        self.color      = color
        self.interlaced = interlaced
    }

    init(_ data:[UInt8]) throws
    {
        guard data.count == 13
        else
        {
            throw PNGReadError.PNGSyntaxError("Image header chunk does not have the correct length")
        }

        guard let color = ColorType(rawValue: Int(data[9]))
        else
        {
            throw PNGReadError.PNGSyntaxError("Color type cannot have a value of \(Int(data[9]))")
        }

        /* validate other fields */
        guard Int(data[10]) == 0
        else
        {
            throw PNGReadError.PNGSyntaxError("Compression method does not equal 0")
        }
        guard Int(data[11]) == 0
        else
        {
            throw PNGReadError.PNGSyntaxError("Filter method does not equal 0")
        }
        let interlaced:Bool
        let interlace_i = Int(data[12]) // TODO: turn this into a switch case
        if interlace_i == 0
        {
            interlaced = false
        }
        else if interlace_i == 1
        {
            interlaced = true
        }
        else
        {
            throw PNGReadError.PNGSyntaxError("Interlace method cannot equal \(interlace_i)")
        }

        // I think it unlikly to ever encounter a PNG with dimensions that overflow a signed Int32
        try self.init(width     : Int(quad_byte_to_uint32(Array(data[0...3]))),
                      height    : Int(quad_byte_to_uint32(Array(data[4...7]))),
                      bit_depth : Int(data[8]),
                      color     : color,
                      interlaced: interlaced)
    }
}

public
struct PNGProperties:CustomStringConvertible
{
    public
    enum ColorType:Int
    {
        case grayscale      = 0,
             rgb            = 2,
             indexed        = 3,
             grayscale_a    = 4,
             rgba           = 6
    }

    public
    let width:Int,
        height:Int,
        bit_depth:Int,
        color:ColorType,
        interlaced:Bool

    public
    let channels:Int

    // other chunks
    public private(set)
    var palatte:[RGBA<UInt8>]?,
        chroma_key:RGBA<UInt16>?//,
    /*
        chromaticity:Chromaticity?,
        gamma:UInt32?
        profile:ColorProfile?
        sBIT:Int?
        sRGB:RenderingIntent?
        bKGD:ColorKey
        hIST:[UInt16],
        pHYs:PhysicalSize,
        sPLT:SuggestedPalatte,
        tIME:Time,

    */

    public
    let sub_dimensions:[(width:Int, height:Int)]
    // expose this just in case someone wants the sub_dimensions without the image data

    let sub_array_bounds:[(i:Int, j:Int)],
        bpp:Int,
        interlaced_data_size:Int,
        noninterlaced_data_size:Int

    private
    typealias SubStrider = (u:StrideTo<Int>, v:StrideTo<Int>)
    private
    let sub_striders:[SubStrider]

    private
    var sub_array_ranges:[Range<Int>]
    {
        var accumulator:Int = 0
        return self.sub_array_bounds.dropLast().map
        {
            let upper:Int = accumulator + $0.i * $0.j
            let range:Range<Int> = accumulator ..< upper
            accumulator = upper
            return range
        }
    }

    public
    var deinterlaced_properties:PNGProperties
    {
        return PNGProperties(width: self.width, height: self.height,
                             bit_depth_unchecked: self.bit_depth,
                             color              : self.color,
                             interlaced         : false)
    }

    public
    var quantum16:UInt16
    {
        return UInt16.max / (UInt16.max >> (16 - UInt16(self.bit_depth)))
    }

    public
    var description:String
    {
        return "<PNG properties>{image dimensions: \(self.width) × \(self.height), bit depth: \(self.bit_depth), color: \(self.color), interlaced: \(self.interlaced)}"
    }

    init(width:Int, height:Int, bit_depth_unchecked bit_depth:Int, color:ColorType, interlaced:Bool)
    {
        self.width      = width
        self.height     = height
        self.bit_depth  = bit_depth
        self.color      = color
        self.interlaced = interlaced

        let channels:Int
        switch color
        {
        case .grayscale, .indexed:
            channels = 1
        case .grayscale_a:
            channels = 2
        case .rgb:
            channels = 3
        case .rgba:
            channels = 4
        }
        self.channels = channels

        self.bpp        = max(1, (channels * bit_depth) >> 3)

        /* calculate size of interlaced subimages, even if the image is not interlaced (to help the deinterlace() function) */
        // 0: (w + 7) >> 3 , (h + 7) >> 3
        // 1: (w + 3) >> 3 , (h + 7) >> 3
        // 2: (w + 3) >> 2 , (h + 3) >> 3
        // 3: (w + 1) >> 2 , (h + 3) >> 2
        // 4: (w + 1) >> 1 , (h + 1) >> 2
        // 5: (w) >> 1     , (h + 1) >> 1
        // 6: (w)          , (h) >> 1
        self.sub_dimensions = [ (width: (width  + 7) >> 3, height: (height + 7) >> 3),
                                (width: (width  + 3) >> 3, height: (height + 7) >> 3),
                                (width: (width  + 3) >> 2, height: (height + 3) >> 3),
                                (width: (width  + 1) >> 2, height: (height + 3) >> 2),
                                (width: (width  + 1) >> 1, height: (height + 1) >> 2),
                                (width:  width       >> 1, height: (height + 1) >> 1),
                                (width:  width       >> 0, height:  height      >> 1),
                                (width:  width           , height:  height          )]
        self.sub_striders   = [ (u: stride(from: 0, to: width, by: 8), v: stride(from: 0, to: height, by: 8)),
                                (u: stride(from: 4, to: width, by: 8), v: stride(from: 0, to: height, by: 8)),
                                (u: stride(from: 0, to: width, by: 4), v: stride(from: 4, to: height, by: 8)),
                                (u: stride(from: 2, to: width, by: 4), v: stride(from: 0, to: height, by: 4)),
                                (u: stride(from: 0, to: width, by: 2), v: stride(from: 2, to: height, by: 4)),
                                (u: stride(from: 1, to: width, by: 2), v: stride(from: 0, to: height, by: 2)),
                                (u: stride(from: 0, to: width, by: 1), v: stride(from: 1, to: height, by: 2))]
        self.sub_array_bounds = self.sub_dimensions.map
        {
            let scanline_bits_n:Int  = $0.width * channels * bit_depth
            let scanline_bytes_n:Int = (scanline_bits_n >> 3) + (scanline_bits_n & 7 == 0 ? 0 : 1)  // ceil(scanline_bits_n/8)
            return (i: $0.height, j: scanline_bytes_n)
        }

        self.interlaced_data_size = self.sub_array_bounds.dropLast().map{ $0.i * $0.j }.reduce(0, +)
        self.noninterlaced_data_size = self.sub_array_bounds[7].i * self.sub_array_bounds[7].j
    }

    init(header:Header)
    {
        self.init(width             : header.width,
                 height             : header.height,
                 bit_depth_unchecked: header.bit_depth,
                 color              : header.color,
                 interlaced         : header.interlaced)
    }

    public
    init?(width:Int, height:Int, bit_depth:Int, color:ColorType, interlaced:Bool)
    {
        do
        {
            self.init(header: try Header(width: width, height: height, bit_depth: bit_depth, color: color, interlaced: interlaced))
        }
        catch
        {
            print(error)
            return nil
        }
    }

    func serialize_header() -> [UInt8]
    {
        var bytes:[UInt8] = uint32_to_quad_byte(UInt32(self.width))        // [0:3]
        bytes.reserveCapacity(12)
        bytes.append(contentsOf: uint32_to_quad_byte(UInt32(self.height))) // [4:7]
        bytes.append(UInt8(self.bit_depth))                             // [8]
        bytes.append(UInt8(self.color.rawValue))                   // [9]
        bytes.append(0)                                                 // [10] = 0
        bytes.append(0)                                                 // [11] = 0
        bytes.append(self.interlaced ? 1 : 0)                            // [12]
        return bytes
    }

    public mutating
    func set_palatte(_ palatte:[RGBA<UInt8>])
    {
        self.palatte = palatte.count > 256 ? Array(palatte[0 ..< 256]) : palatte
    }

    mutating
    func set_palatte(_ bytes:[UInt8]) throws
    {
        guard bytes.count % 3 == 0
        else
        {
            throw PNGReadError.PNGSyntaxError("Palatte is \(bytes.count) bytes long, which is not divisible by 3")
        }

        self.palatte = stride(from: 0, to: min(bytes.count, 1 << self.bit_depth * 3), by: 3).map
        {
            let r:UInt8 = bytes[$0    ],
                g:UInt8 = bytes[$0 + 1],
                b:UInt8 = bytes[$0 + 2]
            return RGBA(r, g, b, UInt8.max)
        }
    }

    mutating
    func set_transparency(_ bytes:[UInt8]) throws
    {
        switch self.color
        {
        case .grayscale:
            guard bytes.count == 2
            else
            {
                throw PNGReadError.PNGSyntaxError("Grayscale chroma key is \(bytes.count) bytes long, but it should be 2 bytes long")
            }

            let quantum:UInt16 = self.quantum16
            let v:UInt16 = quantum * (UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
            self.chroma_key = RGBA(v, v, v, UInt16.max)
        case .rgb:
            guard bytes.count == 6
            else
            {
                throw PNGReadError.PNGSyntaxError("RGB chroma key is \(bytes.count) bytes long, but it should be 6 bytes long")
            }

            let quantum:UInt16 = self.quantum16
            let r:UInt16 = quantum * (UInt16(bytes[0]) << 8 | UInt16(bytes[1])),
                g:UInt16 = quantum * (UInt16(bytes[2]) << 8 | UInt16(bytes[3])),
                b:UInt16 = quantum * (UInt16(bytes[4]) << 8 | UInt16(bytes[5]))
            self.chroma_key = RGBA(r, g, b, UInt16.max)
        case .indexed:
            guard let palatte = self.palatte
            else
            {
                throw PNGReadError.MissingPalatteError
            }

            guard bytes.count <= palatte.count
            else
            {
                throw PNGReadError.PNGSyntaxError("\(bytes.count) chroma keys were provided, but we only have \(palatte.count) palatte entries")
            }

            for (i, alpha):(Int, UInt8) in bytes.enumerated()
            {
                self.palatte![i] = palatte[i].with_alpha(alpha)
            }
            self.chroma_key = nil
        default:
            break // this is an error, but it should have already been caught by PNGConditions
        }
    }

    public
    func decompose(raw_data:[UInt8]) -> [([UInt8], PNGProperties)]?
    {
        guard raw_data.count == self.interlaced_data_size
        else
        {
            return nil
        }

        return zip(self.sub_array_ranges, self.sub_dimensions).map
        {
            (range:Range<Int>, dimensions:(width:Int, height:Int)) in

            let properties:PNGProperties = PNGProperties(width              : dimensions.width,
                                                         height             : dimensions.height,
                                                         bit_depth_unchecked: self.bit_depth,
                                                         color              : self.color,
                                                         interlaced         : false)
            return (Array(raw_data[range]), properties)
        }
    }

    public
    func deinterlace(raw_data:[UInt8]) -> [UInt8]?
    {
        guard raw_data.count == self.interlaced_data_size
        else
        {
            return nil
        }

        var deinterlaced = [UInt8](repeating: 0, count: self.noninterlaced_data_size)

        var src_byte_base:Int = 0
        for (range, (stride_h, stride_v)):(Range<Int>, SubStrider) in zip(self.sub_array_ranges, self.sub_striders)
        {
            var src_pixel_offset:Int = 0
            for dest_pixel_base in stride_v.map({ $0 * self.width })
            {
                for dest_pixel_offset in stride_h
                {
                    if self.bit_depth < 8
                    {
                        // channels is guaranteed to equal 1
                        let src_byte_index:Int   = src_byte_base + (src_pixel_offset * self.bit_depth) >> 3,
                            src_bit_offset:UInt8 =           UInt8((src_pixel_offset * self.bit_depth) & 7)
                        var src_byte:UInt8       = raw_data[src_byte_index]

                        // mask out left
                        src_byte <<= src_bit_offset
                        // mask out right
                        src_byte >>= (8 - UInt8(self.bit_depth))

                        let dest_byte_index:Int   =       ((dest_pixel_base + dest_pixel_offset) * self.bit_depth) >> 3,
                            dest_bit_offset:UInt8 = UInt8(((dest_pixel_base + dest_pixel_offset) * self.bit_depth) & 7)
                        // shift it to destination
                        deinterlaced[dest_byte_index] |= src_byte << (8 - dest_bit_offset - UInt8(self.bit_depth))
                    }
                    else
                    {
                        let dest_byte_index:Int = (dest_pixel_base + dest_pixel_offset) * self.bpp,
                             src_byte_index:Int =    src_byte_base + src_pixel_offset   * self.bpp
                        deinterlaced[dest_byte_index ..< dest_byte_index + self.bpp] =
                            raw_data[src_byte_index  ..< src_byte_index  + self.bpp]
                    }

                    src_pixel_offset += 1
                }
            }
            src_byte_base += range.count
        }

        return deinterlaced
    }

    public
    func rgba32(raw_data:[UInt8]) -> [RGBA<UInt8>]?
    {
        guard raw_data.count == self.noninterlaced_data_size
        else
        {
            return nil
        }

        guard self.bit_depth <= 8
        else
        {
            return nil
        }

        guard self.color != .indexed
        else
        {
            fputs("Normalizing indexed PNGs is unsupported\n", stderr)
            return nil
        }

        let output:[RGBA<UInt8>]
        if self.bit_depth < 8 // channels is guaranteed to be 1
        {
            let quantum:UInt8 = UInt8.max / (UInt8.max >> (8 - UInt8(self.bit_depth)))
            output = stride(from: 0, to: raw_data.count << 3, by: self.bit_depth).map
            {
                let value:UInt8 = quantum * PNGProperties.bitval_extract(bit_index: $0, bits: self.bit_depth, src: raw_data)
                return RGBA(value, value, value, UInt8.max)
            }
        }
        else
        {
            switch self.color
            {
            case .grayscale:
                output = raw_data.map{ value in RGBA(value, value, value, UInt8.max) }
            case .grayscale_a:
                output = stride(from: 0, to: raw_data.count, by: 2).map
                {
                    let value:UInt8 = raw_data[$0]
                    return RGBA(value, value, value, raw_data[$0 + 1])
                }
            case .rgb:
                output = stride(from: 0, to: raw_data.count, by: 3).map
                {
                    let r:UInt8 = raw_data[$0    ],
                        g:UInt8 = raw_data[$0 + 1],
                        b:UInt8 = raw_data[$0 + 2]
                    return RGBA(r, g, b, UInt8.max)
                }
            case .rgba:
                output = stride(from: 0, to: raw_data.count, by: 4).map
                {
                    let r:UInt8 = raw_data[$0    ],
                        g:UInt8 = raw_data[$0 + 1],
                        b:UInt8 = raw_data[$0 + 2],
                        a:UInt8 = raw_data[$0 + 3]
                    return RGBA(r, g, b, a)
                }
            case .indexed:
                return nil // should never reach here
            }
        }

        return output
    }

    private
    func deindex64(indices:[Int], palatte:[RGBA<UInt8>]) -> [RGBA<UInt16>]?
    {
        // check that they don’t exceed the range of the palatte
        guard indices.map({ $0 < palatte.count ? 0 : 1 }).reduce(0, +) == 0
        else
        {
            return nil
        }

        return indices.map
        {
            let r:UInt16 = UInt16(palatte[$0].r),
                g:UInt16 = UInt16(palatte[$0].g),
                b:UInt16 = UInt16(palatte[$0].b),
                a:UInt16 = UInt16(palatte[$0].a)
            return RGBA(r << 8 | r, g << 8 | g, b << 8 | b, a << 8 | a)
        }
    }

    public
    func rgba64(raw_data:[UInt8]) -> [RGBA<UInt16>]?
    {
        guard raw_data.count == self.noninterlaced_data_size
        else
        {
            return nil
        }

        let output:[RGBA<UInt16>]
        if self.bit_depth < 8 // channels is guaranteed to be 1
        {
            // well that’s a mouthful isn’t it...
            let bit_strider:LazySequence<FlattenSequence<LazyMapSequence<StrideTo<Int>, LazySequence<StrideTo<Int>>>>> =
            stride(from: 0, to: self.noninterlaced_data_size, by: self.sub_array_bounds[7].j).lazy.flatMap
            {
                stride(from: $0 << 3, to: $0 << 3 + self.width * self.bit_depth, by: self.bit_depth).lazy
            }

            if self.color == .grayscale
            {
                let quantum:UInt16 = self.quantum16
                output = bit_strider.map
                {
                    let v:UInt16 = quantum * UInt16(PNGProperties.bitval_extract(bit_index: $0, bits: self.bit_depth, src: raw_data))
                    // test against chroma key
                    if let chroma_key = self.chroma_key, chroma_key.compare_opaque(v)
                    {
                        return RGBA(v, v, v, 0)
                    }
                    return RGBA(v, v, v, UInt16.max)
                }
            }
            else // indexed
            {
                guard let palatte = self.palatte
                else
                {
                    return nil
                }

                let indices:[Int] = bit_strider.map
                {
                    Int(PNGProperties.bitval_extract(bit_index: $0, bits: self.bit_depth, src: raw_data))
                }
                return deindex64(indices: indices, palatte: palatte)
            }
        }
        else
        {
            let d:Int = self.bit_depth == 8 ? 0 : 1

            switch self.color
            {
            case .grayscale:
                output = stride(from: 0, to: raw_data.count, by: 1 << d).map
                {
                    let v:UInt16 = UInt16(raw_data[$0         ]) << 8 | UInt16(raw_data[$0 +           d ])
                    if let chroma_key = self.chroma_key, chroma_key.compare_opaque(v)
                    {
                        return RGBA(v, v, v, 0)
                    }
                    return RGBA(v, v, v, UInt16.max)
                }
            case .grayscale_a:
                output = stride(from: 0, to: raw_data.count, by: 2 << d).map
                {
                    let v:UInt16 = UInt16(raw_data[$0         ]) << 8 | UInt16(raw_data[$0 +           d ]),
                        a:UInt16 = UInt16(raw_data[$0 + 1 << d]) << 8 | UInt16(raw_data[$0 + (1 << d | d)])
                    return RGBA(v, v, v, a)
                }
            case .rgb:
                output = stride(from: 0, to: raw_data.count, by: 3 << d).map
                {
                    let r:UInt16 = UInt16(raw_data[$0         ]) << 8 | UInt16(raw_data[$0 +           d ]),
                        g:UInt16 = UInt16(raw_data[$0 + 1 << d]) << 8 | UInt16(raw_data[$0 + (1 << d | d)]),
                        b:UInt16 = UInt16(raw_data[$0 + 2 << d]) << 8 | UInt16(raw_data[$0 + (2 << d | d)])
                    if let chroma_key = self.chroma_key, chroma_key.compare_opaque(r, g, b)
                    {
                        return RGBA(r, g, b, 0)
                    }
                    return RGBA(r, g, b, UInt16.max)
                }
            case .rgba:
                output = stride(from: 0, to: raw_data.count, by: 4 << d).map
                {
                    let r:UInt16 = UInt16(raw_data[$0         ]) << 8 | UInt16(raw_data[$0 +           d ]),
                        g:UInt16 = UInt16(raw_data[$0 + 1 << d]) << 8 | UInt16(raw_data[$0 + (1 << d | d)]),
                        b:UInt16 = UInt16(raw_data[$0 + 2 << d]) << 8 | UInt16(raw_data[$0 + (2 << d | d)]),
                        a:UInt16 = UInt16(raw_data[$0 + 3 << d]) << 8 | UInt16(raw_data[$0 + (3 << d | d)])
                    return RGBA(r, g, b, a)
                }
            case .indexed:
                guard let palatte = self.palatte
                else
                {
                    return nil
                }
                return deindex64(indices: raw_data.map(Int.init), palatte: palatte)
            }
        }

        return output
    }

    static private
    func bitval_extract(bit_index:Int, bits:Int, src:[UInt8]) -> UInt8
    {
        let byte_offset:Int  = bit_index >> 3
        let bit_offset:UInt8 = UInt8(bit_index & 7)
        var src_byte:UInt8   = src[byte_offset]
        /* mask out left */
        src_byte <<= bit_offset
        /* mask out right */
        src_byte >>= (8 - UInt8(bits))
        return src_byte
    }
}

struct PNGConditions
{
    private
    var last_valid_chunk:PNGChunk = PNGChunk.__FIRST__,
        seen:Set<PNGChunk>        = []

    var color:PNGProperties.ColorType?

    mutating
    func update(_ chunk:PNGChunk) throws
    {
        if self.last_valid_chunk == .__FIRST__
        {
            guard chunk == .IHDR
            else
            {
                throw PNGReadError.MissingHeaderError
            }

            self.last_valid_chunk = .IHDR
            self.seen.insert(.IHDR)
            return
        }

        guard (self.last_valid_chunk != .IEND) || (chunk == .IEND && !self.seen.contains(.IDAT))
        else
        {
            throw PNGReadError.PrematureIENDError
        }

        guard let color = self.color
        else
        {
            throw PNGReadError.MissingHeaderError
        }


        if chunk ==                                                                       .tRNS
        {
            if color == .grayscale_a || color == .rgba
            {
                throw PNGReadError.IllegalChunkError(chunk)
            }
        }

        // PLTE must come before bKGD, hIST, and tRNS
        if chunk ==        .PLTE
        {
            if color == .grayscale || color == .grayscale_a
            {
                throw PNGReadError.IllegalChunkError(chunk)
            }

            if self.seen.contains(.bKGD) || self.seen.contains(.hIST) || self.seen.contains(.tRNS)
            {
                throw PNGReadError.ChunkOrderingError(chunk)
            }
        }

        // these chunks must occur before PLTE
        switch chunk
        {
        case                             .cHRM, .gAMA, .iCCP, .sBIT, .sRGB:
            if self.seen.contains(.PLTE)
            {
                throw PNGReadError.ChunkOrderingError(chunk)
            }
        default:
            break
        }

        // these chunks must occur before IDAT
        switch chunk
        {
        case               .PLTE,        .cHRM, .gAMA, .iCCP, .sBIT, .sRGB, .bKGD, .hIST, .tRNS, .pHYs, .sPLT:
            if self.seen.contains(.IDAT)
            {
                throw PNGReadError.ChunkOrderingError(chunk)
            }
        default:
            break
        }

        switch chunk
        {
        // these chunks cannot duplicate
        case        .IHDR, .PLTE, .IEND, .cHRM, .gAMA, .iCCP, .sBIT, .sRGB, .bKGD, .hIST, .tRNS, .pHYs, .sPLT, .tIME:
            if self.seen.contains(chunk)
            {
                throw PNGReadError.DuplicateChunkError(chunk)
            }

        // IDAT blocks much be consecutive
        case .IDAT:
            if self.last_valid_chunk != .IDAT && self.seen.contains(.IDAT)
            {
                throw PNGReadError.ChunkOrderingError(chunk)
            }

            if color == .indexed && !self.seen.contains(.PLTE)
            {
                throw PNGReadError.MissingPalatteError
            }
        default:
            break
        }
        self.last_valid_chunk = chunk
        self.seen.insert(chunk)
    }
}

struct ScanlineIterator
{
    private
    let sub_array_bounds:[(i:Int, j:Int)],
        interlaced:Bool

    private
    var interlace_level:Int = 0,
        scanlines_remaining:Int,
        use_zero_line:UInt8 = 0b10

    private(set)
    var bytes_per_scanline:Int

    var first_scanline:Bool
    {
        return self.use_zero_line != 0
    }

    init(properties:PNGProperties)
    {
        if properties.interlaced
        {
            self.scanlines_remaining = properties.sub_array_bounds[0].i
            self.bytes_per_scanline  = properties.sub_array_bounds[0].j
            self.interlaced = true
        }
        else
        {
            self.scanlines_remaining = properties.sub_array_bounds[7].i
            self.bytes_per_scanline  = properties.sub_array_bounds[7].j
            self.interlaced = false
        }
        self.sub_array_bounds = properties.sub_array_bounds
    }

    mutating
    func update_scanline_size() -> Bool // return false if iteration has reached the end
    {
        guard self.scanlines_remaining > 0
        else
        {
            self.interlace_level    += 1
            guard self.interlaced && self.interlace_level < 7
            else
            {
                return false
            }

            self.scanlines_remaining = self.sub_array_bounds[self.interlace_level].i - 1
            self.bytes_per_scanline  = self.sub_array_bounds[self.interlace_level].j
            self.use_zero_line       = 0b01
            return true
        }

        self.use_zero_line >>= 1 // the first_scanline flag must be set *after* the first call to this function
        self.scanlines_remaining -= 1
        return true
    }

    func make_zero_line() -> [UInt8]
    {
        return [UInt8](repeating: 0, count: self.sub_array_bounds[self.interlaced ? 6 : 7].j) // the most zeros we will ever need
    }
}

struct Decoder
{
    let properties:PNGProperties

    private
    var conditions:PNGConditions = PNGConditions(),
        current_chunk:PNGChunk   = .__FIRST__,
        stream_exhausted:Bool    = false

    private
    let z_iterator:ZInflator

    /*
    public private(set)
    var palatte:[(r: Int, g: Int, b: Int)]? = nil // not implemented
    */

    public
    init(stream:FilePointer, recognizing recognized:Set<PNGChunk>) throws
    {
        // check if it's, you know, actually a PNG
        guard try Decoder.read_buffer(from: stream, length: 8) == PNG_SIGNATURE
        else
        {
            throw PNGReadError.FiletypeError
        }

        // read the image header

        guard let (chunk, chunk_data) = try Decoder.read_chunk(from: stream, conditions: &self.conditions, recognizing: Set([.IHDR]))
        else
        {
            throw PNGReadError.MissingHeaderError
        }
        assert(chunk == .IHDR) // this should already be verified from the PNG conditions struct
        self.current_chunk = .IHDR
        let header:Header = try Header(chunk_data)

        self.conditions.color = header.color
        self.z_iterator       = try ZInflator()

        var properties        = PNGProperties(header: header)

        // read non-IDAT chunks
        //                                     v— recognized generally contains an .IDAT enum to ensure we don’t miss the first .IDAT
        let pre_idat_chunks:Set<PNGChunk> = recognized.union(header.color == .indexed ? [.PLTE, .IEND] : [.IEND])

        outer_loop: while true
        {
            if let (chunk, chunk_data) = try Decoder.read_chunk(from: stream, conditions: &self.conditions, recognizing: pre_idat_chunks)
            {
                self.current_chunk = chunk

                switch chunk
                {
                    case .PLTE:
                        try properties.set_palatte(chunk_data)
                    case .IDAT:
                        self.z_iterator.add_input(chunk_data)
                        break outer_loop // we have a check in the conditions preventing IEND from coming early
                    case .IEND:
                        break outer_loop

                    case .tRNS:
                        try properties.set_transparency(chunk_data)
                    default:
                        fputs("Reading chunk \(chunk) is not yet supported. tragic\n", stderr)
                }
            }
        }

        self.properties = properties
    }

    mutating
    func decompress_scanline(stream:FilePointer, dest:UnsafeMutableBufferPointer<UInt8>) throws -> UInt8
    {
        var filter_byte:UInt8 = 0
        while true
        {
            if let output_byte:UInt8 = try self.z_iterator.get_output_byte(sentinel: &self.stream_exhausted)
            {
                filter_byte = output_byte
                break;
            }

            guard !self.stream_exhausted
            else
            {
                throw PNGReadError.PrematureEOSError
            }

            // if the inflator is out of input
            guard let (_, chunk_data) = try Decoder.read_chunk(from: stream, conditions: &self.conditions, recognizing: Set([.IDAT]))
            else
            {
                // if something besides an IDAT chunk shows up, that’s an invalid PNGChunk
                throw PNGReadError.ChunkOrderingError(.__INTERRUPTOR__)
            }
            self.z_iterator.add_input(chunk_data)
        }

        self.z_iterator.set_output(dest: dest)
        while try self.z_iterator.get_output_bytes(sentinel: &self.stream_exhausted) > 0
        {
            guard !self.stream_exhausted
            else
            {
                throw PNGReadError.PrematureEOSError
            }

            // if the inflator is out of input
            guard let (_, chunk_data) = try Decoder.read_chunk(from: stream, conditions: &self.conditions, recognizing: Set([.IDAT]))
            else
            {
                // if something besides an IDAT chunk shows up, that’s an invalid PNGChunk
                throw PNGReadError.ChunkOrderingError(.__INTERRUPTOR__)
            }
            self.z_iterator.add_input(chunk_data)
        }

        return filter_byte
    }

    // make NO assumptions about the `.count` property of the reference line;
    // it is often greater than the size of the actual data
    func defilter_scanline<ReferenceLine:Collection>(dest:UnsafeMutableBufferPointer<UInt8>, reference:ReferenceLine, filter:UInt8)
    where ReferenceLine.Iterator.Element == UInt8, ReferenceLine.Index == Int
    {
        switch filter
        {
        case 0:
            break
        case 1:
            Decoder.defilter_sub    (dest, bpp: self.properties.bpp)
        case 2:
            Decoder.defilter_up     (dest, previous_line: reference)
        case 3:
            Decoder.defilter_average(dest, previous_line: reference, bpp: self.properties.bpp)
        case 4:
            Decoder.defilter_paeth  (dest, previous_line: reference, bpp: self.properties.bpp)
        default:
            break // won’t happen
        }
    }

    private static
    func defilter_sub(_ buffer:UnsafeMutableBufferPointer<UInt8>, bpp:Int)
    {
        for i in bpp..<buffer.count
        {
            buffer[i] = buffer[i] &+ buffer[i - bpp]
        }
    }

    private static
    func defilter_up<ReferenceLine:Collection>(_ buffer:UnsafeMutableBufferPointer<UInt8>, previous_line:ReferenceLine)
    where ReferenceLine.Iterator.Element == UInt8, ReferenceLine.Index == Int
    {
        for i in 0..<buffer.count
        {
            buffer[i] = buffer[i] &+ previous_line[i]
        }
    }

    private static
    func defilter_average<ReferenceLine:Collection>(_ buffer:UnsafeMutableBufferPointer<UInt8>, previous_line:ReferenceLine, bpp:Int)
    where ReferenceLine.Iterator.Element == UInt8, ReferenceLine.Index == Int
    {
        for i in 0..<bpp
        {
            buffer[i] = buffer[i] &+ previous_line[i] >> 1
        }
        for i in bpp..<buffer.count
        {
            buffer[i] = buffer[i] &+ UInt8((UInt16(buffer[i - bpp]) + UInt16(previous_line[i])) >> 1)
            // the second part will never overflow because of the right shift
        }
    }

    private static
    func defilter_paeth<ReferenceLine:Collection>(_ buffer:UnsafeMutableBufferPointer<UInt8>, previous_line:ReferenceLine, bpp:Int)
    where ReferenceLine.Iterator.Element == UInt8, ReferenceLine.Index == Int
    {
        for i in 0..<bpp
        {
            buffer[i] = buffer[i] &+ paeth(0, previous_line[i], 0)
        }
        for i in bpp..<buffer.count
        {
            buffer[i] = buffer[i] &+ paeth(buffer[i - bpp], previous_line[i], previous_line[i - bpp])
        }
    }

    private static
    func read_buffer(from stream:FilePointer, length:Int) throws -> [UInt8]
    {
        var buffer = [UInt8](repeating: 0, count: length)
        guard fread(&buffer, 1, length, stream) == length
        else
        {
            throw PNGReadError.IncompleteChunkError
        }
        return buffer
    }

    private static
    func skip_buffer(from stream:FilePointer, length:Int) throws
    {
        if length <= 128 // most regulated-length png chunks are shorter than 128 bytes
        {
            let _ = try Decoder.read_buffer(from: stream, length: length + 4) // 4 bytes for CRC32
        }
        else
        {
            fseek(stream, length, SEEK_CUR)
            let _ = try Decoder.read_buffer(from: stream, length: 4) // read a throwaway buffer, also corresponds to CRC32
        }
    }

    // this function only used for error messages
    private static
    func buffer_to_string(_ buffer:[UInt8]) -> String
    {
        return String(buffer.flatMap(UnicodeScalar.init).map(Character.init))
    }

    private static
    func read_chunk(from stream:FilePointer, conditions:inout PNGConditions, recognizing recognized:Set<PNGChunk>)
    throws -> (chunk:PNGChunk, chunk_data:[UInt8])?
    {
        // if any of our chunks are greater than 2**31 bytes long, we are fucked
        let ulength:UInt32 = quad_byte_to_uint32(try Decoder.read_buffer(from: stream, length: 4))
        let length:Int     = Int(ulength)

        /* — CHUNK TYPE READ AND VALIDATION — */
        let chunk_name_buffer = try Decoder.read_buffer(from: stream, length: 4)
        guard let chunk = PNGChunk(buffer: chunk_name_buffer)
        else
        {
            guard (chunk_name_buffer[0] & (1 << 5)) != 0
            else
            {
                throw PNGReadError.UnexpectedCriticalChunkError(Decoder.buffer_to_string(chunk_name_buffer))
            }
            guard (chunk_name_buffer[2] & (1 << 5)) == 0
            else
            {
                throw PNGReadError.PNGSyntaxError("Third byte of chunk type \(Decoder.buffer_to_string(chunk_name_buffer)) must have bit 5 set to 0.")
            }

            try Decoder.skip_buffer(from: stream, length: length)
            // ignore unrecognized chunk
            fputs("unrecognized: \(Decoder.buffer_to_string(chunk_name_buffer))", stderr)
            return nil
        }
        // all the recognized chunks have valid names so there’s no need to check them

        // check ordering conditions
        try conditions.update(chunk)
        if recognized.contains(chunk)
        {
            let chunk_data = try Decoder.read_buffer(from: stream, length: length)

            let stored_chunk_crc:UInt = UInt(quad_byte_to_uint32(try Decoder.read_buffer(from: stream, length: 4)))
            var calculated_crc:UInt   = crc32(0, chunk_name_buffer, 4)
                calculated_crc        = crc32(calculated_crc, chunk_data, ulength)
            guard stored_chunk_crc == calculated_crc
            else
            {
                throw PNGReadError.DataCorruptionError(chunk.rawValue)
            }
            return (chunk, chunk_data)
        }
        else
        {
            try Decoder.skip_buffer(from: stream, length: length)
            return nil
        }
    }
}

public final
class PNGDecoder
{
    private
    var decoder:Decoder,
        scanline_iter:ScanlineIterator,
        stream:FilePointer,

        reference_line:[UInt8] = []

    private
    let zero_line:[UInt8]

    public
    var properties:PNGProperties { return self.decoder.properties }

    public
    init(path:String, recognizing recognized:Set<PNGChunk> = Set([.IDAT])) throws
    {
        if let stream:FilePointer = fopen(posix_path(path), "rb")
        {
            self.stream = stream
        }
        else
        {
            throw PNGReadError.FileError(posix_path(path))
        }

        self.decoder        = try Decoder(stream: stream, recognizing: recognized)
        self.scanline_iter  = ScanlineIterator(properties: self.decoder.properties)
        self.zero_line      = self.scanline_iter.make_zero_line()
    }

    deinit
    {
        fclose(self.stream)
    }

    public
    func next_scanline() throws -> [UInt8]?
    {
        guard self.scanline_iter.update_scanline_size()
        else
        {
            return nil
        }

        var buffer:[UInt8] = [UInt8](repeating: 0, count: self.scanline_iter.bytes_per_scanline)
        try buffer.withUnsafeMutableBufferPointer
        {
            (bp) in

            let filter:UInt8 = try self.decoder.decompress_scanline(stream: self.stream, dest: bp)
            if self.scanline_iter.first_scanline
            {
                self.zero_line.withUnsafeBufferPointer
                {
                    self.decoder.defilter_scanline(dest: bp, reference: $0, filter: filter)
                }
            }
            else
            {
                self.reference_line.withUnsafeBufferPointer
                {
                    self.decoder.defilter_scanline(dest: bp, reference: $0, filter: filter)
                }
            }
        }

        self.reference_line = buffer
        return buffer
    }
}

struct Encoder
{
    private
    var chunk_data:[UInt8],
        chunk_capacity_remaining:Int

    private
    let bpp:Int,
        z_iterator:ZDeflator

    init(stream:FilePointer, properties:PNGProperties, chunk_size:Int) throws
    {
        self.bpp            = properties.bpp
        self.z_iterator     = try ZDeflator()
        self.chunk_data     = [UInt8](repeating: 0, count: chunk_size)
        self.chunk_capacity_remaining = chunk_size

        try Encoder.write_buffer(to: stream, buffer: PNG_SIGNATURE)
        try Encoder.write_chunk(to: stream, chunk_data: properties.serialize_header(), chunk: .IHDR)
    }

    // make NO assumptions about the `.count` property of the reference line;
    // it is often greater than the size of the actual data
    func filter_scanline<ReferenceLine:Collection>(src:UnsafeBufferPointer<UInt8>, reference:ReferenceLine)
    where ReferenceLine.Iterator.Element == UInt8, ReferenceLine.Index == Int
    {
        var filter_data = [[UInt8]](repeating: [0] + src, count: 5)

        Encoder.filter_sub    (&filter_data[1], bpp: self.bpp)
        Encoder.filter_up     (&filter_data[2], previous_line: reference)
        Encoder.filter_average(&filter_data[3], previous_line: reference, bpp: self.bpp)
        Encoder.filter_paeth  (&filter_data[4], previous_line: reference, bpp: self.bpp)

        /* pick the most effective filter */
        let scores:[Int] = filter_data.map(Encoder.score)
        var min_filter:Int = 0
        var min_score:Int = Int.max
        for (i, score) in scores.enumerated()
        {
            if score < min_score
            {
                min_score = score
                min_filter = i
            }
        }

        filter_data[min_filter][0] = UInt8(min_filter)
        self.z_iterator.add_input(filter_data[min_filter])
    }

    mutating
    func compress_scanline(stream:FilePointer, finish:Bool) throws
    {
        var stream_exhausted:Bool = false
        repeat
        {
            try self.chunk_data.withUnsafeMutableBufferPointer
            {
                let dest_base:UnsafeMutablePointer<UInt8> = $0.baseAddress! + ($0.count - self.chunk_capacity_remaining)
                let dest = UnsafeMutableBufferPointer<UInt8>(start: dest_base, count: self.chunk_capacity_remaining)
                self.z_iterator.set_output(dest: dest)
                // like with the Inflator, the above is tracked internally by the zstream, but we can’t guarantee
                // the stability of the underlying `chunk_data` buffer so we recalculate the destination each cycle.

                self.chunk_capacity_remaining = Int(try self.z_iterator.get_output(sentinel: &stream_exhausted, finish: finish))
                assert(!stream_exhausted || finish) // the_end cannot come yet
            }
        } while try self.attempt_emit_idat_chunk(stream: stream)
        assert(stream_exhausted || !finish)
    }

    mutating
    func finish(stream:FilePointer) throws
    {
        try self.compress_scanline(stream: stream, finish: true)

        if self.chunk_capacity_remaining != self.chunk_data.count // meaning, there is still data in the buffer
        {
            let remnant:[UInt8] = [UInt8](self.chunk_data.dropLast(self.chunk_capacity_remaining))
            try Encoder.write_chunk(to: stream, chunk_data: remnant, chunk: .IDAT)
        }
        try Encoder.write_chunk(to: stream, chunk_data: [], chunk: .IEND)
    }

    private mutating
    func attempt_emit_idat_chunk(stream:FilePointer) throws -> Bool
    {
        if self.chunk_capacity_remaining == 0
        {
            /* emit chunk */
            try Encoder.write_chunk(to: stream, chunk_data: self.chunk_data, chunk: .IDAT)
            self.chunk_capacity_remaining = self.chunk_data.count
            return true
        }
        else
        {
            return false
        }
    }

    /* these are literally exactly the same as the defilter functions except backwards */
    private static
    func filter_sub(_ buffer:inout [UInt8], bpp:Int)
    {
        for i in ((1 + bpp)..<buffer.count).reversed()
        {
            buffer[i] = buffer[i] &- buffer[i - bpp]
        }
    }

    private static
    func filter_up<ReferenceLine:Collection>(_ buffer:inout [UInt8], previous_line:ReferenceLine)
    where ReferenceLine.Iterator.Element == UInt8, ReferenceLine.Index == Int
    {
        for i in 1..<buffer.count // we do not need to reverse here
        {
            buffer[i] = buffer[i] &- previous_line[i - 1]
        }
    }

    private static
    func filter_average<ReferenceLine:Collection>(_ buffer:inout [UInt8], previous_line:ReferenceLine, bpp:Int)
    where ReferenceLine.Iterator.Element == UInt8, ReferenceLine.Index == Int
    {
        for i in ((1 + bpp)..<buffer.count).reversed()
        {
            buffer[i] = buffer[i] &- UInt8((UInt16(buffer[i - bpp]) + UInt16(previous_line[i - 1])) >> 1) // the second part will never overflow because of the right shift
        }
        for i in 1..<(1 + bpp) // we do not need to reverse here
        {
            buffer[i] = buffer[i] &- previous_line[i - 1] >> 1
        }
    }

    private static
    func filter_paeth<ReferenceLine:Collection>(_ buffer:inout [UInt8], previous_line:ReferenceLine, bpp:Int)
    where ReferenceLine.Iterator.Element == UInt8, ReferenceLine.Index == Int
    {

        for i in ((1 + bpp)..<buffer.count).reversed()
        {
            buffer[i] = buffer[i] &- paeth(buffer[i - bpp], previous_line[i - 1], previous_line[i - 1 - bpp])
        }
        for i in 1..<(1 + bpp)
        {
            buffer[i] = buffer[i] &- paeth(0, previous_line[i - 1], 0)
        }
    }

    private static
    func score(_ filtered:[UInt8]) -> Int
    {
        guard filtered.count > 0
        else
        {
            return 0
        }
        var changes:Int = 0
        var last:UInt8 = filtered[0]
        for byte in filtered.dropFirst()
        {
            changes += byte == last ? 0 : 1
            last = byte
        }
        return changes
    }

    private static
    func write_buffer(to stream:FilePointer, buffer:[UInt8]) throws
    {
        guard fwrite(buffer, 1, buffer.count, stream) == buffer.count
        else
        {
            throw PNGWriteError.FileWriteError
        }
    }

    private static
    func write_chunk(to stream:FilePointer, chunk_data:[UInt8], chunk:PNGChunk) throws
    {
        try Encoder.write_buffer(to: stream, buffer: uint32_to_quad_byte(UInt32(chunk_data.count))) // length section
        let chunk_name_buffer:[UInt8] = [UInt8](chunk.rawValue.utf8)
        assert(chunk_name_buffer.count == 4)
        try Encoder.write_buffer(to: stream, buffer: chunk_name_buffer) // chunk type section
        try Encoder.write_buffer(to: stream, buffer: chunk_data) // chunk data section
        var calculated_crc:UInt = crc32(0, chunk_name_buffer, 4)
            calculated_crc      = crc32(calculated_crc, chunk_data, UInt32(chunk_data.count))
        try Encoder.write_buffer(to: stream, buffer: uint32_to_quad_byte(UInt32(calculated_crc))) // crc section
        // this Int() cast only works because crc is a 32 bit value padded to 64 bits
    }
}

public final
class PNGEncoder
{
    private
    var encoder:Encoder,
        stream:FilePointer,

        reference_line:[UInt8]

    public
    init(path:String, properties:PNGProperties, chunk_size:Int = DEFAULT_CHUNK_SIZE) throws
    {
        if let stream = fopen(posix_path(path), "wb")
        {
            self.stream = stream
        }
        else
        {
            throw PNGReadError.FileError(posix_path(path))
        }

        self.reference_line = [UInt8](repeating: 0, count: properties.sub_array_bounds[7].j)
        self.encoder = try Encoder(stream: self.stream, properties: properties, chunk_size: chunk_size)
    }

    deinit
    {
        fclose(self.stream)
    }

    public
    func add_scanline(_ src:[UInt8]) throws
    {
        guard src.count == reference_line.count
        else
        {
            throw PNGWriteError.DimemsionError
        }

        src.withUnsafeBufferPointer
        {
            self.encoder.filter_scanline(src: $0, reference: self.reference_line)
        }

        self.reference_line = src

        try self.encoder.compress_scanline(stream: self.stream, finish: false)
    }

    public
    func finish() throws
    {
        try self.encoder.finish(stream: self.stream)
    }
}

public
func decode_png(path:String, recognizing recognized:Set<PNGChunk> = Set([.IDAT])) throws -> ([UInt8], PNGProperties)
{
    guard let stream:FilePointer = fopen(posix_path(path), "rb")
    else
    {
        throw PNGReadError.FileError(posix_path(path))
    }
    defer { fclose(stream) }

    var decoder:Decoder                = try Decoder(stream: stream, recognizing: recognized),
        scanline_iter:ScanlineIterator = ScanlineIterator(properties: decoder.properties)

    let zero_line:[UInt8]              = scanline_iter.make_zero_line()

    let buffer_size:Int = decoder.properties.interlaced ?
                                decoder.properties.interlaced_data_size :
                                decoder.properties.noninterlaced_data_size
    var buffer:[UInt8]  = [UInt8](repeating: 0, count: buffer_size)
    try buffer.withUnsafeMutableBufferPointer
    {
        (bp) in

        var offset:Int = 0
        var reference_line:UnsafeBufferPointer<UInt8>?
        while scanline_iter.update_scanline_size()
        {
            let dest = UnsafeMutableBufferPointer<UInt8>(start: bp.baseAddress! + offset, count: scanline_iter.bytes_per_scanline)
            //print("allocated: \(bp.baseAddress!  ) – \(bp.baseAddress! + bp.count) , offset = \(offset)/\(buffer_size)")
            //print("write to : \(dest.baseAddress!) – \(dest.baseAddress! + dest.count) (\(_count))")
            let filter:UInt8 = try decoder.decompress_scanline(stream: stream, dest: dest)
            if scanline_iter.first_scanline
            {
                decoder.defilter_scanline(dest: dest, reference: zero_line, filter: filter)
            }
            else
            {
                decoder.defilter_scanline(dest: dest, reference: reference_line!, filter: filter)
            }

            reference_line = UnsafeBufferPointer(start: dest.baseAddress, count: dest.count)
            offset += scanline_iter.bytes_per_scanline
        }
    }

    return (buffer, decoder.properties)
}

public
func encode_png(path:String, raw_data:[UInt8], properties:PNGProperties, chunk_size:Int = DEFAULT_CHUNK_SIZE) throws
{
    guard raw_data.count == properties.noninterlaced_data_size
    else
    {
        throw PNGWriteError.DimemsionError
    }

    guard let stream:FilePointer = fopen(posix_path(path), "wb")
    else
    {
        throw PNGReadError.FileError(posix_path(path))
    }
    defer { fclose(stream) }

    var encoder:Encoder        = try Encoder(stream: stream, properties: properties, chunk_size: chunk_size)

    let bytes_per_scanline:Int = properties.sub_array_bounds[7].j
    let zero_line:[UInt8]      = [UInt8](repeating: 0, count: bytes_per_scanline)

    try raw_data.withUnsafeBufferPointer
    {
        bp in

        var reference_line:UnsafeBufferPointer<UInt8>?

        let src = UnsafeBufferPointer<UInt8>(start: bp.baseAddress!, count: bytes_per_scanline)
        encoder.filter_scanline(src: src, reference: zero_line)
        reference_line = src
        try encoder.compress_scanline(stream: stream, finish: false)

        for offset in stride(from: bytes_per_scanline, to: raw_data.count, by: bytes_per_scanline)
        {
            let src = UnsafeBufferPointer<UInt8>(start: bp.baseAddress! + offset, count: bytes_per_scanline)
            encoder.filter_scanline(src: src, reference: reference_line!)
            reference_line = src
            try encoder.compress_scanline(stream: stream, finish: false)
        }
    }

    try encoder.finish(stream: stream)
}

class ZIterator
{
    var stream:z_stream_s
    var input_ref:[UInt8] = [] // strongref the input buffer to prevent it from being deallocated prematurely

    init() throws
    {
        self.stream          = z_stream()
        self.stream.zalloc   = nil
        self.stream.zfree    = nil
        self.stream.opaque   = nil
        self.stream.avail_in = 0
        self.stream.next_in  = nil
    }

    final
    func add_input(_ input:[UInt8])
    {
        self.input_ref       = input
        self.stream.avail_in = UInt32(input.count)
        self.stream.next_in  = UnsafeMutablePointer<UInt8>(mutating: self.input_ref)
    }

    final
    func set_output(dest:UnsafeMutableBufferPointer<UInt8>)
    {
        self.stream.avail_out = UInt32(dest.count)
        self.stream.next_out  = dest.baseAddress
    }
}

final
class ZInflator : ZIterator
// we cannot lower this to a struct because otherwise Swift clobbers Zlib’s internal state with its value semantics
{
    override
    init() throws
    {
        try super.init()
        guard inflateInit(&self.stream) == Z_OK
        else
        {
            throw PNGDecompressionError.StreamError
        }
    }

    deinit
    {
        inflateEnd(&self.stream)
    }

    func get_output_byte(sentinel:inout Bool) throws -> UInt8?
    {
        let _byte = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        defer { _byte.deallocate(capacity: 1) }

        self.stream.avail_out = 1
        self.stream.next_out = _byte

        let inflate_status:Int32 = inflate(&self.stream, Z_NO_FLUSH)
        assert(inflate_status != Z_STREAM_ERROR) // this should never happen
        switch inflate_status
        {
            case Z_NEED_DICT:
                throw PNGDecompressionError.MissingDictionaryError
            case Z_DATA_ERROR:
                throw PNGDecompressionError.DataError
            case Z_MEM_ERROR:
                throw PNGDecompressionError.MemoryError
            default:
                break
        }

        sentinel = inflate_status == Z_STREAM_END

        guard self.stream.avail_out == 0
        else
        {
            return nil
        }

        return _byte.pointee
    }

    func get_output_bytes(sentinel:inout Bool) throws -> UInt32
    {
        let inflate_status:Int32 = inflate(&self.stream, Z_NO_FLUSH)
        assert(inflate_status != Z_STREAM_ERROR) // this should never happen
        switch inflate_status
        {
            case Z_NEED_DICT:
                throw PNGDecompressionError.MissingDictionaryError
            case Z_DATA_ERROR:
                throw PNGDecompressionError.DataError
            case Z_MEM_ERROR:
                throw PNGDecompressionError.MemoryError
            default:
                break
        }

        sentinel = inflate_status == Z_STREAM_END
        return self.stream.avail_out
    }
}

final
class ZDeflator : ZIterator
{
    override
    init() throws
    {
        try super.init()
        guard deflateInit(&self.stream, 9) == Z_OK
        else
        {
            throw PNGCompressionError.StreamError
        }
    }

    deinit
    {
        deflateEnd(&self.stream)
    }

    func get_output(sentinel:inout Bool, finish:Bool) throws -> UInt32
    {
        let deflate_status:Int32 = deflate(&stream, finish ? Z_FINISH : Z_NO_FLUSH)
        assert(deflate_status != Z_STREAM_ERROR) // this should never happen

        sentinel = deflate_status == Z_STREAM_END
        return self.stream.avail_out
    }
}

// If you are wondering why these functions exist, it’s because Swift doesn’t know how to import C function macros yet.
func inflateInit(_ strm:inout z_stream_s) -> Int32
{
    return inflateInit_(&strm, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
}

func deflateInit(_ strm:inout z_stream_s, _ level:Int32) -> Int32
{
    return deflateInit_(&strm, level, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
}
