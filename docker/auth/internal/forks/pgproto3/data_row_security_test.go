package pgproto3

import "testing"

func TestDataRowDecodeRejectsNegativeFieldLength(t *testing.T) {
	for _, tt := range []struct {
		name string
		length [4]byte
	}{
		{name: "minus two", length: [4]byte{0xff, 0xff, 0xff, 0xfe}},
		{name: "minimum int32", length: [4]byte{0x80, 0x00, 0x00, 0x00}},
	} {
		t.Run(tt.name, func(t *testing.T) {
			// One field followed by a signed field length. Invalid negative
			// lengths previously reached a slice operation and panicked.
			input := append([]byte{0x00, 0x01}, tt.length[:]...)
			var row DataRow
			if err := row.Decode(input); err == nil {
				t.Fatal("expected invalid field length to return an error")
			}
		})
	}
}

func TestDataRowDecodePreservesNullField(t *testing.T) {
	var row DataRow
	if err := row.Decode([]byte{0x00, 0x01, 0xff, 0xff, 0xff, 0xff}); err != nil {
		t.Fatalf("null field should decode: %v", err)
	}
	if len(row.Values) != 1 || row.Values[0] != nil {
		t.Fatalf("expected one null field, got %#v", row.Values)
	}
}
