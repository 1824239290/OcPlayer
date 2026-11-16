/* Diagnostic-only FFmpeg probe/decode sampler. It does not render or map DV RPU. */
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/dovi_meta.h>
#include <libavutil/hwcontext.h>
#include <libavutil/pixdesc.h>
#include <libavutil/time.h>

typedef struct TrackDecoder {
    AVCodecContext *codec;
    AVStream *stream;
    int index, frames, hardware_frames, dovi_rpu_frames, dovi_metadata_frames, errors, done;
    double first_pts, last_pts;
} TrackDecoder;

static enum AVPixelFormat hardware_format = AV_PIX_FMT_NONE;
static enum AVPixelFormat choose_format(AVCodecContext *codec, const enum AVPixelFormat *formats) {
    (void)codec;
    for (const enum AVPixelFormat *p=formats; *p!=AV_PIX_FMT_NONE; ++p)
        if (*p==hardware_format) return *p;
    return formats[0];
}
static void json_string(const char *s) {
    putchar('"');
    if (s) for (const unsigned char *p=(const unsigned char *)s; *p; ++p) {
        if (*p=='"' || *p=='\\') printf("\\%c",*p);
        else if (*p<32) printf("\\u%04x",*p);
        else putchar(*p);
    }
    putchar('"');
}
static int fail(const char *stage, int error) {
    char text[AV_ERROR_MAX_STRING_SIZE]; av_strerror(error,text,sizeof text);
    fprintf(stderr,"%s: %s\n",stage,text); return 1;
}
static void drain(TrackDecoder *decoder, AVFrame *frame, double start, double end) {
    int result;
    while ((result=avcodec_receive_frame(decoder->codec,frame))>=0) {
        int64_t stamp=frame->best_effort_timestamp;
        if (stamp!=AV_NOPTS_VALUE) {
            double pts=stamp*av_q2d(decoder->stream->time_base);
            if (pts>=end) decoder->done=1;
            if (pts>=start && pts<end) {
                if (!decoder->frames) decoder->first_pts=pts;
                decoder->last_pts=pts; ++decoder->frames;
                if (av_frame_get_side_data(frame,AV_FRAME_DATA_DOVI_RPU_BUFFER)) ++decoder->dovi_rpu_frames;
                if (av_frame_get_side_data(frame,AV_FRAME_DATA_DOVI_METADATA)) ++decoder->dovi_metadata_frames;
                if (frame->format==hardware_format && hardware_format!=AV_PIX_FMT_NONE)
                    ++decoder->hardware_frames;
            }
        }
        av_frame_unref(frame);
    }
    if (result!=AVERROR(EAGAIN) && result!=AVERROR_EOF) ++decoder->errors;
}

int wmain(int argc, wchar_t **argv) {
    if (argc<2) { fprintf(stderr,"usage: native_media_probe MEDIA [START_SECONDS] [SECONDS] [hardware]\n"); return 2; }
    int size=WideCharToMultiByte(CP_UTF8,0,argv[1],-1,NULL,0,NULL,NULL);
    char *path=malloc(size); WideCharToMultiByte(CP_UTF8,0,argv[1],-1,path,size,NULL,NULL);
    double start=argc>2 ? wcstod(argv[2],NULL) : 0;
    double seconds=argc>3 ? wcstod(argv[3],NULL) : 8;
    int use_hardware=argc>4 && !wcscmp(argv[4],L"hardware");
    AVFormatContext *format=NULL;
    int result=avformat_open_input(&format,path,NULL,NULL); free(path);
    if (result<0) return fail("open",result);
    result=avformat_find_stream_info(format,NULL);
    if (result<0) { avformat_close_input(&format); return fail("probe",result); }
    av_dump_format(format,0,format->url,0);
    double duration=format->duration==AV_NOPTS_VALUE ? 0 : (double)format->duration/AV_TIME_BASE;
    printf("{\"ffmpeg\":"); json_string(av_version_info());
    printf(",\"durationSeconds\":%.6f,\"startSeconds\":%.3f,\"sampleSeconds\":%.3f,\"hardwareRequested\":%s,\"streams\":[",duration,start,seconds,use_hardware?"true":"false");
    for (unsigned i=0; i<format->nb_streams; ++i) {
        AVStream *stream=format->streams[i]; AVCodecParameters *p=stream->codecpar;
        if(i) putchar(',');
        printf("{\"index\":%u,\"type\":",i); json_string(av_get_media_type_string(p->codec_type));
        printf(",\"codec\":"); json_string(avcodec_get_name(p->codec_id));
        AVDictionaryEntry *language=av_dict_get(stream->metadata,"language",NULL,0);
        printf(",\"language\":"); json_string(language?language->value:"");
        printf(",\"width\":%d,\"height\":%d,\"sampleRate\":%d,\"channels\":%d,\"fps\":%.6f",p->width,p->height,p->sample_rate,p->ch_layout.nb_channels,stream->avg_frame_rate.den?av_q2d(stream->avg_frame_rate):0.0);
        if(p->codec_type==AVMEDIA_TYPE_VIDEO) {
            printf(",\"pixelFormat\":"); json_string(av_get_pix_fmt_name(p->format));
            printf(",\"primaries\":"); json_string(av_color_primaries_name(p->color_primaries));
            printf(",\"transfer\":"); json_string(av_color_transfer_name(p->color_trc));
            const AVPacketSideData *side=av_packet_side_data_get(p->coded_side_data,p->nb_coded_side_data,AV_PKT_DATA_DOVI_CONF);
            if(side && side->size>=sizeof(AVDOVIDecoderConfigurationRecord)) {
                const AVDOVIDecoderConfigurationRecord *dv=(const void *)side->data;
                printf(",\"dolbyVision\":{\"profile\":%u,\"level\":%u,\"rpu\":%u,\"enhancementLayer\":%u,\"baseLayer\":%u,\"compatibilityID\":%u}",dv->dv_profile,dv->dv_level,dv->rpu_present_flag,dv->el_present_flag,dv->bl_present_flag,dv->dv_bl_signal_compatibility_id);
            }
        }
        putchar('}');
    }
    printf("],\"decode\":["); fflush(stdout);
    TrackDecoder *decoders=calloc(format->nb_streams,sizeof *decoders);
    AVBufferRef *device=NULL;
    if (use_hardware) {
        result=av_hwdevice_ctx_create(&device,AV_HWDEVICE_TYPE_D3D11VA,NULL,NULL,0);
        if(result<0) { avformat_close_input(&format); free(decoders); return fail("d3d11va device",result); }
    }
    int decoder_count=0;
    for(unsigned i=0; i<format->nb_streams; ++i) {
        AVStream *stream=format->streams[i];
        if(stream->codecpar->codec_type!=AVMEDIA_TYPE_VIDEO && stream->codecpar->codec_type!=AVMEDIA_TYPE_AUDIO) continue;
        const AVCodec *codec=avcodec_find_decoder(stream->codecpar->codec_id);
        if(!codec) continue;
        TrackDecoder *decoder=&decoders[i]; decoder->index=i; decoder->stream=stream;
        decoder->codec=avcodec_alloc_context3(codec);
        avcodec_parameters_to_context(decoder->codec,stream->codecpar);
        decoder->codec->pkt_timebase=stream->time_base;
        decoder->codec->thread_count=0;
        if(device && stream->codecpar->codec_type==AVMEDIA_TYPE_VIDEO) {
            for(int j=0;;++j) {
                const AVCodecHWConfig *config=avcodec_get_hw_config(codec,j);
                if(!config) break;
                if(config->device_type==AV_HWDEVICE_TYPE_D3D11VA && (config->methods&AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX)) {
                    hardware_format=config->pix_fmt;
                    decoder->codec->hw_device_ctx=av_buffer_ref(device);
                    decoder->codec->get_format=choose_format; break;
                }
            }
        }
        result=avcodec_open2(decoder->codec,codec,NULL);
        if(result<0) { fail("decoder",result); avcodec_free_context(&decoder->codec); continue; }
        ++decoder_count;
    }
    if(start>0) {
        result=avformat_seek_file(format,-1,INT64_MIN,(int64_t)(start*AV_TIME_BASE),INT64_MAX,AVSEEK_FLAG_BACKWARD);
        if(result<0) { avformat_close_input(&format); return fail("seek",result); }
        for(unsigned i=0;i<format->nb_streams;++i) if(decoders[i].codec) avcodec_flush_buffers(decoders[i].codec);
    }
    AVPacket *packet=av_packet_alloc(); AVFrame *frame=av_frame_alloc();
    int64_t started=av_gettime_relative();
    while((result=av_read_frame(format,packet))>=0) {
        TrackDecoder *decoder=&decoders[packet->stream_index];
        if(decoder->codec && !decoder->done) {
            result=avcodec_send_packet(decoder->codec,packet);
            if(result==AVERROR(EAGAIN)) { drain(decoder,frame,start,start+seconds); result=avcodec_send_packet(decoder->codec,packet); }
            if(result<0) ++decoder->errors;
            drain(decoder,frame,start,start+seconds);
        }
        av_packet_unref(packet);
        int done=0; for(unsigned i=0;i<format->nb_streams;++i) if(decoders[i].codec && decoders[i].done) ++done;
        if(done==decoder_count) break;
    }
    if(result==AVERROR_EOF) for(unsigned i=0;i<format->nb_streams;++i) if(decoders[i].codec) { avcodec_send_packet(decoders[i].codec,NULL); drain(&decoders[i],frame,start,start+seconds); }
    double elapsed=(av_gettime_relative()-started)/1000000.0;
    int printed=0, errors=0, empty=0;
    for(unsigned i=0;i<format->nb_streams;++i) if(decoders[i].codec) {
        TrackDecoder *decoder=&decoders[i]; if(printed++) putchar(',');
        printf("{\"stream\":%u,\"frames\":%d,\"hardwareFrames\":%d,\"doviRpuFrames\":%d,\"doviMetadataFrames\":%d,\"errors\":%d,\"firstPTS\":%.6f,\"lastPTS\":%.6f}",i,decoder->frames,decoder->hardware_frames,decoder->dovi_rpu_frames,decoder->dovi_metadata_frames,decoder->errors,decoder->first_pts,decoder->last_pts);
        errors+=decoder->errors; empty+=!decoder->frames;
        avcodec_free_context(&decoder->codec);
    }
    printf("],\"elapsedSeconds\":%.6f,\"errors\":%d,\"emptyStreams\":%d}\n",elapsed,errors,empty);
    av_frame_free(&frame); av_packet_free(&packet); av_buffer_unref(&device);
    avformat_close_input(&format); free(decoders);
    return errors || empty || !decoder_count ? 1 : 0;
}
