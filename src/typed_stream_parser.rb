# typedstream_parser.rb
# Core logic for parsing Apple's typedstream format, inspired by the Rust TypedStreamReader
# This is a skeleton for further extension.

class TypedStreamParser
  # Control Tags
  I_16 = 0x81 # Indicates a 16-bit integer follows
  I_32 = 0x82 # Indicates a 32-bit integer follows
  DECIMAL = 0x83 # Indicates a float/double follows (size determined by type encoding)
  START = 0x84 # Start of a new object definition
  EMPTY = 0x85 # Placeholder or end of an inheritance chain
  END_TAG = 0x86 # Marks the end of an object's field list
  # REFERENCE_TAG and above are indices into tables
  REFERENCE_TAG = 0x92 # Minimum value for a reference pointer to type/object table

  # Type Markers (subset, can be extended)
  # These are bytes found in type encoding strings
  OBJECT_TYPE = 0x40 # '@' - An Objective-C object
  UTF8_STRING_TYPE = 0x2B # '+' - A UTF-8 string (often used for NSString content)
  EMBEDDED_DATA_TYPE = 0x2A # '*' - Embedded data, often another typedstream
  FLOAT_TYPE = 0x66 # 'f' - A float
  DOUBLE_TYPE = 0x64 # 'd' - A double
  # Signed Integers
  CHAR_TYPE = 0x63 # 'c' - char / int8
  INT_TYPE = 0x69 # 'i' - int / int32
  LONG_TYPE = 0x6c # 'l' - long / int32 on 32-bit, int64 on 64-bit (treat as int32 for now for simplicity with iMessage)
  LONGLONG_TYPE = 0x71 # 'q' - long long / int64
  SHORT_TYPE = 0x73 # 's' - short / int16
  # Unsigned Integers
  UCHAR_TYPE = 0x43 # 'C' - unsigned char
  UINT_TYPE = 0x49 # 'I' - unsigned int
  ULONG_TYPE = 0x4c # 'L' - unsigned long
  ULONGLONG_TYPE = 0x51 # 'Q' - unsigned long long
  USHORT_TYPE = 0x53 # 'S' - unsigned short

  # Header constants
  EXPECTED_VERSION = 4
  EXPECTED_SIGNATURE = 'streamtyped'
  EXPECTED_SYSTEM_VERSION = 1000 # This can vary, but 1000 is common

  class TypedStreamError < StandardError; end

  attr_reader :stream, :idx, :types_table, :object_table

  def initialize(stream_bytes)
    @stream = stream_bytes # Expect bytes (array of integers 0-255)
    @idx = 0
    # For a new parse, these tables will be fresh.
    # If reusing the parser instance for multiple streams, clear them in parse().
    @types_table = []
    @object_table = []
  end

  def parse
    @idx = 0 # Reset index for new parse
    @types_table = []
    @object_table = []

    validate_header

    parsed_components = []
    while @idx < @stream.size
      # Skip any trailing END_TAGs at the top level if they exist
      break if [END_TAG, EMPTY].include?(current_byte)

      component = read_next_component
      parsed_components << component if component
    end
    parsed_components
  end

  def validate_header
    version = read_byte # Version is a single byte

    # Read signature: first its length, then the string itself
    signature_actual_length = read_byte # This should be the byte  (11 decimal)

    # Check if the reported length in the stream matches the expected length of "streamtyped"
    unless signature_actual_length == EXPECTED_SIGNATURE.length
      raise TypedStreamError, "Reported signature length in stream (#{signature_actual_length}) " \
                             "does not match expected length for \"#{EXPECTED_SIGNATURE}\" (#{EXPECTED_SIGNATURE.length})."
    end

    # Read the signature string using the length obtained from the stream
    signature_bytes = read_bytes(signature_actual_length)
    signature = signature_bytes.pack('C*').force_encoding('UTF-8')

    # The Rust code uses read_signed_int() for system_version. Let's try to mimic that.
    # However, a simple 4-byte read was in the original Ruby version.
    # Let's stick to a simpler fixed-size read for system version for now matching old Ruby.
    # If issues arise, this is a place to make more robust.
    @idx += 4 # Skip 4 bytes for system version as per original validate_header logic.
    # This is a simplification. A full read_signed_int here would be more correct.

    unless version == EXPECTED_VERSION
      raise TypedStreamError, "Invalid typedstream version. Expected #{EXPECTED_VERSION}, got #{version}"
    end
    # Compare the read signature with the expected constant
    return if signature == EXPECTED_SIGNATURE

    raise TypedStreamError, "Invalid typedstream signature. Expected \"#{EXPECTED_SIGNATURE}\", got \"#{signature}\""

    # System version check can be added here if read properly
    # unless system_version == EXPECTED_SYSTEM_VERSION
    #   raise TypedStreamError, "Invalid system version. Expected #{EXPECTED_SYSTEM_VERSION}, got #{system_version}"
    # end
  end

  def read_next_component
    # This is the main dispatcher for reading elements from the stream.
    # An element can be an object definition (START), a reference, or direct typed data.
    # This mirrors the Rust parser's loop: get_type, then read_types.

    # Handle immediate end markers or empty markers if they appear unexpectedly
    # The main parse loop should ideally catch these for top level.
    return nil if @idx >= @stream.size || current_byte == END_TAG || current_byte == EMPTY

    types = get_current_types_from_stream
    return nil if types.nil? || types.empty? # Should not happen if stream is well-formed

    # read_values_for_types returns an array of values.
    # For a top-level component, we typically expect one "archivable" item.
    # If types define multiple values not part of a single object, this might need adjustment.
    # For now, assume it returns an array, and we take the first meaningful one, or the array itself
    # if it's a simple data array.
    values = read_values_for_types(types)

    # If read_values_for_types returns an array with a single item, return that item.
    # Otherwise, the array itself might be the component (e.g., an array of integers).
    values.is_a?(Array) && values.size == 1 ? values.first : values
  end

  def get_current_types_from_stream
    # Determines the type(s) for the upcoming data.
    # Can be a new type definition or a reference to an existing one.
    tag = current_byte
    if tag >= REFERENCE_TAG
      type_ref_idx = read_reference_pointer_value
      @types_table.fetch(type_ref_idx) { raise TypedStreamError, "Invalid type reference index: #{type_ref_idx}" }
    else
      # A new type definition to be read from the stream
      new_types = read_type_definition_from_stream
      @types_table << new_types # Add to table for future reference
      new_types
    end
  end

  def read_type_definition_from_stream
    # Reads a type encoding string/sequence from the stream.
    # Example: stream might have `0x01 0x2B` (length 1, type byte for UTF8_STRING_TYPE)
    length = read_unsigned_int_value # Length of the type encoding string/sequence
    type_bytes = read_bytes(length) # The actual type encoding bytes

    parsed_type_symbols = []
    type_bytes.each do |byte|
      parsed_type_symbols << map_byte_to_type_symbol(byte)
    end
    parsed_type_symbols
  end

  def map_byte_to_type_symbol(byte)
    case byte
    when OBJECT_TYPE then :object_val
    when UTF8_STRING_TYPE then :utf8_string_val
    when EMBEDDED_DATA_TYPE then :embedded_data_val
    when FLOAT_TYPE then :float_val
    when DOUBLE_TYPE then :double_val
    when CHAR_TYPE then :i8_val
    when SHORT_TYPE then :i16_val
    when INT_TYPE then :i32_val # Common case for 'i'
    when LONG_TYPE then :i64_val # Assuming 'l' maps to 64-bit for simplicity, though platform dependent
    when LONGLONG_TYPE then :i64_val # 'q'
    when UCHAR_TYPE then :u8_val
    when USHORT_TYPE then :u16_val
    when UINT_TYPE then :u32_val
    when ULONG_TYPE then :u64_val
    when ULONGLONG_TYPE then :u64_val
    # Array markers '[', pointer markers '^' etc. would need more complex parsing here.
    # For now, supporting direct type bytes.
    else
      # raise TypedStreamError, "Unknown type byte in type definition: 0x#{byte.to_s(16)}"
      :unknown_type_val # Or handle as error
    end
  end

  def read_values_for_types(type_symbols_array)
    # Given an array of type symbols, reads corresponding values from the stream.
    values = []
    type_symbols_array.each do |type_sym|
      case type_sym
      when :utf8_string_val
        len = read_unsigned_int_value
        str_val = read_string(len)
        values << { type: :string_data, value: str_val }
      when :object_val
        # This means an object is expected here. It could be a new definition (START) or a reference.
        values << read_object_definition_or_reference
      when :i8_val
        values << { type: :integer_data, value: read_signed_int_value(1) } # Assuming read_signed_int_value can take size
      when :i16_val
        values << { type: :integer_data, value: read_signed_int_value(2) }
      when :i32_val
        values << { type: :integer_data, value: read_signed_int_value(4) }
      when :i64_val
        values << { type: :integer_data, value: read_signed_int_value(8) } # Might need specific 8-byte reader
      when :u8_val
        values << { type: :integer_data, value: read_unsigned_int_value(1) }
      when :u16_val
        values << { type: :integer_data, value: read_unsigned_int_value(2) }
      when :u32_val
        values << { type: :integer_data, value: read_unsigned_int_value(4) }
      when :u64_val
        values << { type: :integer_data, value: read_unsigned_int_value(8) } # Might need specific 8-byte reader
      when :float_val
        val_bytes = read_bytes(4)
        values << { type: :float_data, value: val_bytes.pack('C*').unpack1('e') } # 32-bit float, little-endian
      when :double_val
        val_bytes = read_bytes(8)
        values << { type: :double_data, value: val_bytes.pack('C*').unpack1('E') } # 64-bit double, little-endian
      when :embedded_data_val
        # Embedded data starts with START (0x84), then types, then data.
        raise TypedStreamError, 'Expected START for embedded data' unless current_byte == START

        read_byte # Consume START byte
        # Now, the embedded data itself is a typed stream component
        values << read_next_component # Recursive call for the embedded part
      else
        # raise TypedStreamError, "Unsupported type symbol in read_values_for_types: #{type_sym}"
        # For unknown types, we might try to skip or log. For now, let's add a placeholder.
        values << { type: :unknown_data, original_symbol: type_sym }
        # To skip robustly, we'd need to know its size or structure.
      end
    end
    values
  end

  def read_object_definition_or_reference
    tag = current_byte
    if tag == START
      read_object_definition
    elsif tag >= REFERENCE_TAG
      read_object_reference
    else
      raise TypedStreamError, "Expected START or object reference, got 0x#{tag.to_s(16)}"
    end
  end

  def read_object_definition
    read_byte # Consume current object's START tag (0x84).

    obj_idx = @object_table.size
    @object_table << :placeholder

    object_actual_class_info = nil

    # Peek at the next byte to decide how the class information is encoded.
    peek_tag = current_byte

    if peek_tag == START || (peek_tag >= REFERENCE_TAG && peek_tag <= 0xFF)
      # Case 1: This object's class is defined by a nested object or a reference.
      # This is typical for an instance whose class is a separate, complex object definition.
      class_defining_object_component = read_object_definition_or_reference

      unless class_defining_object_component.is_a?(Hash) && class_defining_object_component[:arch_type] == :object
        raise TypedStreamError,
              "Expected class object from nested definition, got #{class_defining_object_component.inspect} at index #{@idx}"
      end

      object_actual_class_info = class_defining_object_component[:class_info]
      unless object_actual_class_info.is_a?(Hash) && object_actual_class_info[:name]
        raise TypedStreamError,
              "Nested class object component missing valid :class_info: #{class_defining_object_component.inspect}"
      end
      # After the class_defining_object_component is fully parsed (including its own END_TAG),
      # @idx is positioned to read the fields of the *current* object (the instance).
    else
      # Case 2: This object defines its class name and version directly as simple values.
      # This is typical for class objects themselves, or simpler direct objects.
      # read_unsigned_int_value will be called here only if peek_tag was not START/REFERENCE.
      class_name_len = read_unsigned_int_value
      class_name = read_string(class_name_len)
      # Assuming class version is a single byte as per typical class object definitions.
      version = read_byte
      object_actual_class_info = { name: class_name, version: version }
      # @idx is now past the version byte, positioned for this object's fields (e.g., superclass for a class object).
    end

    # Now, read the fields for the *current* object being defined.
    fields = []
    until current_byte == END_TAG
      break if @idx >= @stream.size # Safety break

      # Special handling for EMPTY (0x85) if it represents end of superclass chain or nil field.
      # For now, assume EMPTY is not a type that get_current_types_from_stream handles directly.
      # If EMPTY is a field's value, its type should precede it.
      # If EMPTY means "no superclass" for a class object, it often appears just before its END_TAG.
      # This might require more nuanced field parsing for class objects.
      # The original code just tried to get types and read values.

      # If EMPTY is immediately followed by END_TAG, it often means no more fields/superclass.
      # This check is a simplified heuristic. A robust parser might treat EMPTY as a typed nil.
      if current_byte == EMPTY && (@idx + 1 < @stream.size && @stream[@idx + 1] == END_TAG)
        read_byte # Consume EMPTY
        fields << { type: :empty_marker, value: nil } # Represent EMPTY explicitly if needed
        break # No more fields, outer loop will consume END_TAG
      end
      # If EMPTY is not followed by END_TAG, it might be part of a more complex field structure
      # or an error. For now, let get_current_types_from_stream attempt to handle or fail.

      field_types = get_current_types_from_stream
      if field_types.nil?
        # This might occur if stream ends unexpectedly or if current_byte is unhandled (e.g. a bare EMPTY not caught above)
        raise TypedStreamError,
              "Failed to get field types for object of class '#{object_actual_class_info[:name]}' at index #{@idx}. Current byte: 0x#{current_byte.to_s(16)}"
      end

      field_values = read_values_for_types(field_types)
      fields.concat(field_values)
    end
    read_byte # Consume END_TAG for the current object.

    parsed_object = { arch_type: :object, class_info: object_actual_class_info, fields: fields }
    @object_table[obj_idx] = parsed_object
    parsed_object
  end

  def read_object_reference
    ref_idx = read_reference_pointer_value
    @object_table.fetch(ref_idx) { raise TypedStreamError, "Invalid object reference index: #{ref_idx}" }
  end

  def read_reference_pointer_value
    # Reads a reference pointer byte and calculates the index
    raw_val = read_byte
    raise TypedStreamError, "Invalid reference tag value: #{raw_val}" if raw_val < REFERENCE_TAG

    raw_val - REFERENCE_TAG
  end

  # Primitive Readers
  # These need to handle specific byte counts if given, or dynamic tags like I_16/I_32

  def read_unsigned_int_value(fixed_size_bytes = nil)
    if fixed_size_bytes
      val_bytes = read_bytes(fixed_size_bytes)
      case fixed_size_bytes
      when 1 then return val_bytes.pack('C*').unpack1('C')
      when 2 then return val_bytes.pack('C*').unpack1('S<') # Unsigned 16-bit little-endian
      when 4 then return val_bytes.pack('C*').unpack1('L<') # Unsigned 32-bit little-endian
      when 8 # Unsigned 64-bit little-endian. 'Q<' for unpack.
        low = val_bytes[0..3].pack('C*').unpack1('L<')
        high = val_bytes[4..7].pack('C*').unpack1('L<')
        return (high << 32) | low
      else raise TypedStreamError, "Unsupported fixed size for unsigned int: #{fixed_size_bytes}"
      end
    end

    # Dynamic size based on tag
    tag = current_byte
    case tag
    when I_16
      read_byte # Consume tag
      read_bytes(2).pack('C*').unpack1('S<')
    when I_32
      read_byte # Consume tag
      read_bytes(4).pack('C*').unpack1('L<')
    when START, EMPTY, END_TAG
      raise TypedStreamError, "Expected unsigned integer value, got control tag 0x#{tag.to_s(16)} at index #{@idx}"
    when REFERENCE_TAG..0xFF # Check range for reference tags
      raise TypedStreamError, "Expected unsigned integer value, got reference tag 0x#{tag.to_s(16)} at index #{@idx}"
    else # Assumed to be a single byte integer
      read_byte
    end
  end

  def read_signed_int_value(fixed_size_bytes = nil)
    if fixed_size_bytes
      val_bytes = read_bytes(fixed_size_bytes)
      case fixed_size_bytes
      when 1 then return val_bytes.pack('C*').unpack1('c') # Signed 8-bit
      when 2 then return val_bytes.pack('C*').unpack1('s<') # Signed 16-bit little-endian
      when 4 then return val_bytes.pack('C*').unpack1('l<') # Signed 32-bit little-endian
      when 8
        low = val_bytes[0..3].pack('C*').unpack1('L<') # Read as unsigned parts
        high = val_bytes[4..7].pack('C*').unpack1('l<') # Read high part as signed
        return (high << 32) | low
      else raise TypedStreamError, "Unsupported fixed size for signed int: #{fixed_size_bytes}"
      end
    end

    # Dynamic size based on tag
    tag = current_byte
    case tag
    when I_16
      read_byte # Consume tag
      read_bytes(2).pack('C*').unpack1('s<')
    when I_32
      read_byte # Consume tag
      read_bytes(4).pack('C*').unpack1('l<')
    when START, EMPTY, END_TAG
      raise TypedStreamError, "Expected signed integer value, got control tag 0x#{tag.to_s(16)} at index #{@idx}"
    when REFERENCE_TAG..0xFF # Check range for reference tags
      raise TypedStreamError, "Expected signed integer value, got reference tag 0x#{tag.to_s(16)} at index #{@idx}"
    else # Assumed to be a single byte signed integer
      val_bytes = read_bytes(1)
      val_bytes.pack('C*').unpack1('c')
    end
  end

  def read_string(length)
    # read_bytes advances @idx by length
    read_bytes(length).pack('C*').force_encoding('UTF-8')
  end

  def read_bytes(n)
    raise TypedStreamError, 'Attempt to read past end of stream' if (@idx + n) > @stream.size

    bytes_slice = @stream[@idx, n]
    @idx += n
    bytes_slice
  end

  def read_byte
    raise TypedStreamError, 'Attempt to read past end of stream' if @idx >= @stream.size

    byte = @stream[@idx]
    @idx += 1
    byte
  end

  def current_byte
    raise TypedStreamError, 'Attempt to peek past end of stream' if @idx >= @stream.size

    @stream[@idx]
  end

  # Helper method to extract just the text from a message
  def to_s
    # Re-parse if called directly, or assume parse has been called.
    # For safety, let's re-parse or ensure parse is called.
    # If initialize is always with new data, this is fine.
    # If parser instance is reused, ensure parse() is called.

    # Ensure parse is run if tables are empty (first time for this stream)
    # This simple check might not be robust if parse can result in empty tables legitimately.
    # A better way is for `to_s` to always work on the *result* of a `parse` call.
    # Let's assume `parse` has been called or will be called to populate object_table.
    # If not, the user of the class should call `parser.parse` first.

    # The `parse` method now returns the top-level components.
    # We need to iterate these and find the specific NSString/NSMutableString.

    all_parsed_objects = @object_table.reject { |obj| obj == :placeholder } + parse
    # The above line is a bit problematic logic-wise. `parse()` populates `@object_table`.
    # Let's assume `parse()` has been called by the user or by `to_s` itself.

    # Call parse to get the list of top-level archivable objects
    components = parse

    components.each do |component|
      next unless component.is_a?(Hash) && component[:arch_type] == :object

      class_info = component[:class_info]
      next unless class_info && %w[NSString NSMutableString].include?(class_info[:name])

      # Expect the first field to be the string data
      fields = component[:fields]
      return fields.first[:value] if fields&.first&.is_a?(Hash) && fields.first[:type] == :string_data
    end

    # Fallback: if no direct NSString object found at top level,
    # check if any object in the object_table (populated by parse) matches.
    # This is because the main text might be nested.
    @object_table.each do |obj|
      next if obj == :placeholder # Skip placeholders
      next unless obj.is_a?(Hash) && obj[:arch_type] == :object

      class_info = obj[:class_info]
      if class_info && %w[NSString NSMutableString].include?(class_info[:name])
        fields = obj[:fields]
        return fields.first[:value] if fields&.first&.is_a?(Hash) && fields.first[:type] == :string_data
      end
    end

    nil # Or return empty string: ""
  end
end

# Example usage (assuming the class is in a file that can be required):
# data_bytes = File.binread('path_to_typedstream_file').bytes
# parser = TypedStreamParser.new(data_bytes)
# text = parser.to_s
# puts text
#
# Or to see all parsed components:
# components = parser.parse
# pp components
