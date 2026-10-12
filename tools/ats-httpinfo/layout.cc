// Prints the layout of the ATS structs a marshalled alternate vector is made
// of, as compiled. Built by build.sh; output is src/testdata/hdr_layout.txt.
//   field  STRUCT.MEMBER OFFSET SIZE
//   bits   STRUCT.MEMBER BYTE_OFFSET BIT_SHIFT BIT_WIDTH   (in a little-endian u32 at BYTE_OFFSET)
//   const  NAME VALUE
#include "proxy/hdrs/HTTP.h"
#include "proxy/hdrs/HdrHeap.h"
#include "proxy/hdrs/MIME.h"
#include "proxy/hdrs/URL.h"
#include <cstdint>
#include <cstdio>
#include <cstring>

#pragma GCC diagnostic ignored "-Winvalid-offsetof"
#pragma GCC diagnostic ignored "-Woverflow"

#define FIELD(T, m)  printf("field %s.%s %zu %zu\n", #T, #m, offsetof(T, m), sizeof(((T *)nullptr)->m))
#define SIZE(T)      printf("const sizeof(%s) %zu\n", #T, sizeof(T))
#define CONST(name)  printf("const %s %lld\n", #name, (long long)(name))

// Finds a bitfield by setting it to all ones in a zeroed object.
#define BITS(T, m)                                                                   \
  do {                                                                               \
    alignas(16) static unsigned char buf[sizeof(T)];                                 \
    memset(buf, 0, sizeof(buf));                                                     \
    T *p = reinterpret_cast<T *>(buf);                                               \
    p->m = ~0u;                                                                      \
    size_t first = 0;                                                                \
    while (first < sizeof(T) && buf[first] == 0) ++first;                            \
    size_t at = first & ~size_t(3);                                                  \
    uint32_t w;                                                                      \
    memcpy(&w, buf + at, 4);                                                         \
    int shift = __builtin_ctz(w);                                                    \
    int width = __builtin_popcount(w);                                               \
    printf("bits %s.%s %zu %d %d\n", #T, #m, at, shift, width);                      \
  } while (0)

int
main()
{
  SIZE(HTTPCacheAlt);
  printf("const HTTP_ALT_MARSHAL_SIZE %d\n", int(HdrHeapMarshalBlocks{swoc::round_up(sizeof(HTTPCacheAlt))}));
  FIELD(HTTPCacheAlt, m_magic);
  FIELD(HTTPCacheAlt, m_writeable);
  FIELD(HTTPCacheAlt, m_unmarshal_len);
  FIELD(HTTPCacheAlt, m_id);
  FIELD(HTTPCacheAlt, m_rid);
  FIELD(HTTPCacheAlt, m_object_key);
  FIELD(HTTPCacheAlt, m_object_size);
  FIELD(HTTPCacheAlt, m_request_hdr);
  FIELD(HTTPCacheAlt, m_response_hdr);
  FIELD(HTTPCacheAlt, m_request_sent_time);
  FIELD(HTTPCacheAlt, m_response_received_time);
  FIELD(HTTPCacheAlt, m_frag_offset_count);
  FIELD(HTTPCacheAlt, m_frag_offsets);
  FIELD(HTTPCacheAlt, m_integral_frag_offsets);
  FIELD(HTTPHdr, m_heap);
  CONST(HTTPCacheAlt::N_INTEGRAL_FRAG_OFFSETS);

  SIZE(HdrHeap);
  printf("const HDR_HEAP_HDR_SIZE %d\n", int(HDR_HEAP_HDR_SIZE));
  FIELD(HdrHeap, m_magic);
  FIELD(HdrHeap, m_free_start);
  FIELD(HdrHeap, m_data_start);
  FIELD(HdrHeap, m_size);
  FIELD(HdrHeap, m_writeable);
  FIELD(HdrHeap, m_next);
  FIELD(HdrHeap, m_free_size);
  FIELD(HdrHeap, m_ronly_heap);
  SIZE(StrHeapDesc);
  FIELD(StrHeapDesc, m_heap_start);
  FIELD(StrHeapDesc, m_heap_len);

  BITS(HdrHeapObjImpl, m_type);
  BITS(HdrHeapObjImpl, m_length);
  BITS(HdrHeapObjImpl, m_obj_flags);

  SIZE(HTTPHdrImpl);
  FIELD(HTTPHdrImpl, m_polarity);
  FIELD(HTTPHdrImpl, m_version);
  FIELD(HTTPHdrImpl, u.req.m_url_impl);
  FIELD(HTTPHdrImpl, u.req.m_ptr_method);
  FIELD(HTTPHdrImpl, u.req.m_len_method);
  FIELD(HTTPHdrImpl, u.req.m_method_wks_idx);
  FIELD(HTTPHdrImpl, u.resp.m_ptr_reason);
  FIELD(HTTPHdrImpl, u.resp.m_len_reason);
  FIELD(HTTPHdrImpl, u.resp.m_status);
  FIELD(HTTPHdrImpl, m_fields_impl);

  SIZE(MIMEHdrImpl);
  FIELD(MIMEHdrImpl, m_fblock_list_tail);
  FIELD(MIMEHdrImpl, m_first_fblock);

  SIZE(MIMEFieldBlockImpl);
  CONST(MIME_FIELD_BLOCK_SLOTS);
  FIELD(MIMEFieldBlockImpl, m_freetop);
  FIELD(MIMEFieldBlockImpl, m_next);
  FIELD(MIMEFieldBlockImpl, m_field_slots);

  SIZE(MIMEField);
  FIELD(MIMEField, m_ptr_name);
  FIELD(MIMEField, m_ptr_value);
  FIELD(MIMEField, m_next_dup);
  FIELD(MIMEField, m_wks_idx);
  FIELD(MIMEField, m_len_name);
  BITS(MIMEField, m_len_value);
  BITS(MIMEField, m_readiness);
  BITS(MIMEField, m_flags);
  CONST(MIME_FIELD_SLOT_READINESS_LIVE);

  SIZE(URLImpl);
  FIELD(URLImpl, m_len_scheme);
  FIELD(URLImpl, m_len_user);
  FIELD(URLImpl, m_len_password);
  FIELD(URLImpl, m_len_host);
  FIELD(URLImpl, m_len_port);
  FIELD(URLImpl, m_len_path);
  FIELD(URLImpl, m_len_params);
  FIELD(URLImpl, m_len_query);
  FIELD(URLImpl, m_len_fragment);
  FIELD(URLImpl, m_len_printed_string);
  FIELD(URLImpl, m_ptr_scheme);
  FIELD(URLImpl, m_ptr_user);
  FIELD(URLImpl, m_ptr_password);
  FIELD(URLImpl, m_ptr_host);
  FIELD(URLImpl, m_ptr_port);
  FIELD(URLImpl, m_ptr_path);
  FIELD(URLImpl, m_ptr_params);
  FIELD(URLImpl, m_ptr_query);
  FIELD(URLImpl, m_ptr_fragment);
  FIELD(URLImpl, m_ptr_printed_string);
  FIELD(URLImpl, m_port);
  FIELD(URLImpl, m_url_type);
}
