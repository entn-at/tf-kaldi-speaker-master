#!/bin/bash
# Copyright   2017   Johns Hopkins University (Author: Daniel Garcia-Romero)
#             2017   Johns Hopkins University (Author: Daniel Povey)
#        2017-2018   David Snyder
#             2018   Ewald Enzinger
#             2019   Yi Liu. Modified to support network training using TensorFlow
# Apache 2.0.
#
#
# See ../README.txt for more info on data required.
# Results (mostly equal error-rates) are inline in comments below.

# make sure to modify "cmd.sh" and "path.sh", change the KALDI_ROOT to the correct directory
. ./cmd.sh
. ./path.sh
set -e

root=/liry_tf/tf-kaldi-speaker/egs/voxceleb/sre
data=$root/data
exp=$root/exp_kftdnn
mfccdir=$root/mfcc
vaddir=$root/mfcc
sre18_dev_trials=$data/sre18_dev_test/trials
sre18_eval_trials=$data/sre18_eval_test/trials
sre19_eval_trials=$data/sre19_eval_test/trials
stage=9

# The kaldi voxceleb egs directory
kaldi_voxceleb=/home/liry/ruyun/kaldi/egs/voxceleb

voxceleb1_trials=$data/voxceleb1_test/trials
voxceleb1_root=/data2/liry/voxceleb/voxceleb1
voxceleb2_root=/data2/liry/voxceleb/voxceleb2
musan_root=/data2/liry/musan
rirs_root=/home/liry/ruyun/kaldi/egs/sre16/v2/RIRS_NOISES

if [ $stage -le -1 ]; then
    # link the directories
    rm -fr utils steps sid conf local
    ln -s $kaldi_voxceleb/v2/utils ./
    ln -s $kaldi_voxceleb/v2/steps ./
    ln -s $kaldi_voxceleb/v2/sid ./
    ln -s $kaldi_voxceleb/v2/conf ./
    ln -s $kaldi_voxceleb/v2/local ./
    echo "finish link"
    exit
fi

if [ $stage -le 0 ]; then
 # local/make_voxceleb2.pl $voxceleb2_root dev $data/voxceleb2_train
 # local/make_voxceleb2.pl $voxceleb2_root test $data/voxceleb2_test
  # This script reates data/voxceleb1_test and data/voxceleb1_train.
  # Our evaluation set is the test portion of VoxCeleb1.
  local/make_voxceleb1.pl $voxceleb1_root $data
  # We'll train on all of VoxCeleb2, plus the training portion of VoxCeleb1.
  # This should give 7,351 speakers and 1,277,503 utterances.
  utils/combine_data.sh $data/voxceleb_train $data/voxceleb2_train $data/voxceleb2_test $data/voxceleb1_train
fi

if [ $stage -le 1 ]; then
  # Make MFCCs and compute the energy-based VAD for each dataset
  for name in voxceleb_train voxceleb1_test; do
    steps/make_mfcc.sh --write-utt2num-frames true --mfcc-config conf/mfcc.conf --nj 40 --cmd "$train_cmd" \
      $data/${name} $exp/make_mfcc $mfccdir
    utils/fix_data_dir.sh $data/${name}
    sid/compute_vad_decision.sh --nj 40 --cmd "$train_cmd" \
      $data/${name} $exp/make_vad $vaddir
    utils/fix_data_dir.sh $data/${name}
  done
fi

# In this section, we augment the VoxCeleb2 data with reverberation,
# noise, music, and babble, and combine it with the clean data.
if [ $stage -le 2 ]; then
  frame_shift=0.01
  awk -v frame_shift=$frame_shift '{print $1, $2*frame_shift;}' $data/voxceleb_train/utt2num_frames > $data/voxceleb_train/reco2dur

  # Make sure you already have the RIRS_NOISES dataset
#  # Make a version with reverberated speech
#  rvb_opts=()
#  rvb_opts+=(--rir-set-parameters "0.5, RIRS_NOISES/simulated_rirs/smallroom/rir_list")
#  rvb_opts+=(--rir-set-parameters "0.5, RIRS_NOISES/simulated_rirs/mediumroom/rir_list")

  # Make a reverberated version of the VoxCeleb2 list.  Note that we don't add any
  # additive noise here.
  python steps/data/reverberate_data_dir.py \
    "${rvb_opts[@]}" \
    --speech-rvb-probability 1 \
    --pointsource-noise-addition-probability 0 \
    --isotropic-noise-addition-probability 0 \
    --num-replications 1 \
    --source-sampling-rate 16000 \
    $data/voxceleb_train $data/voxceleb_train_reverb
  cp $data/voxceleb_train/vad.scp $data/voxceleb_train_reverb/
  utils/copy_data_dir.sh --utt-suffix "-reverb" $data/voxceleb_train_reverb $data/voxceleb_train_reverb.new
  rm -rf $data/voxceleb_train_reverb
  mv $data/voxceleb_train_reverb.new $data/voxceleb_train_reverb

  # Prepare the MUSAN corpus, which consists of music, speech, and noise
  # suitable for augmentation.
  local/make_musan.sh $musan_root $data

  # Get the duration of the MUSAN recordings.  This will be used by the
  # script augment_data_dir.py.
  for name in speech noise music; do
    utils/data/get_utt2dur.sh $data/musan_${name}
    mv $data/musan_${name}/utt2dur $data/musan_${name}/reco2dur
  done

  # Augment with musan_noise
  python steps/data/augment_data_dir.py --utt-suffix "noise" --fg-interval 1 --fg-snrs "15:10:5:0" --fg-noise-dir "$data/musan_noise" $data/voxceleb_train $data/voxceleb_train_noise
  # Augment with musan_music
  python steps/data/augment_data_dir.py --utt-suffix "music" --bg-snrs "15:10:8:5" --num-bg-noises "1" --bg-noise-dir "$data/musan_music" $data/voxceleb_train $data/voxceleb_train_music
  # Augment with musan_speech
  python steps/data/augment_data_dir.py --utt-suffix "babble" --bg-snrs "20:17:15:13" --num-bg-noises "3:4:5:6:7" --bg-noise-dir "$data/musan_speech" $data/voxceleb_train $data/voxceleb_train_babble

  # Combine reverb, noise, music, and babble into one directory.
  utils/combine_data.sh $data/voxceleb_train_aug $data/voxceleb_train_reverb $data/voxceleb_train_noise $data/voxceleb_train_music $data/voxceleb_train_babble
fi

if [ $stage -le 3 ]; then
  # Take a random subset of the augmentations
  utils/subset_data_dir.sh $data/voxceleb_train_aug 1000000 $data/voxceleb_train_aug_1m
  utils/fix_data_dir.sh $data/voxceleb_train_aug_1m

  # Make MFCCs for the augmented data.  Note that we do not compute a new
  # vad.scp file here.  Instead, we use the vad.scp from the clean version of
  # the list.
  steps/make_mfcc.sh --mfcc-config conf/mfcc.conf --nj 40 --cmd "$train_cmd" \
    $data/voxceleb_train_aug_1m $exp/make_mfcc $mfccdir

  # Combine the clean and augmented VoxCeleb2 list.  This is now roughly
  # double the size of the original clean list.
  utils/combine_data.sh $data/voxceleb_train_combined $data/voxceleb_train_aug_1m $data/voxceleb_train
fi

# Now we prepare the features to generate examples for xvector training.
if [ $stage -le 4 ]; then
  local/nnet3/xvector/prepare_feats_for_egs.sh --nj 40 --cmd "$train_cmd" \
    $data/voxceleb_train_combined $data/voxceleb_train_combined_no_sil $exp/voxceleb_train_combined_no_sil
  utils/fix_data_dir.sh $data/voxceleb_train_combined_no_sil
fi

if [ $stage -le 5 ]; then
  # Now, we need to remove features that are too short after removing silence
  # frames.  We want atleast 5s (500 frames) per utterance.
  min_len=500
  mv $data/voxceleb_train_combined_no_sil/utt2num_frames $data/voxceleb_train_combined_no_sil/utt2num_frames.bak
  awk -v min_len=${min_len} '$2 > min_len {print $1, $2}' $data/voxceleb_train_combined_no_sil/utt2num_frames.bak > $data/voxceleb_train_combined_no_sil/utt2num_frames
  utils/filter_scp.pl $data/voxceleb_train_combined_no_sil/utt2num_frames $data/voxceleb_train_combined_no_sil/utt2spk > $data/voxceleb_train_combined_no_sil/utt2spk.new
  mv $data/voxceleb_train_combined_no_sil/utt2spk.new $data/voxceleb_train_combined_no_sil/utt2spk
  utils/fix_data_dir.sh $data/voxceleb_train_combined_no_sil

  # We also want several utterances per speaker. Now we'll throw out speakers
  # with fewer than 8 utterances.
  min_num_utts=8
  awk '{print $1, NF-1}' $data/voxceleb_train_combined_no_sil/spk2utt > $data/voxceleb_train_combined_no_sil/spk2num
  awk -v min_num_utts=${min_num_utts} '$2 >= min_num_utts {print $1, $2}' $data/voxceleb_train_combined_no_sil/spk2num | utils/filter_scp.pl - $data/voxceleb_train_combined_no_sil/spk2utt > $data/voxceleb_train_combined_no_sil/spk2utt.new
  mv $data/voxceleb_train_combined_no_sil/spk2utt.new $data/voxceleb_train_combined_no_sil/spk2utt
  utils/spk2utt_to_utt2spk.pl $data/voxceleb_train_combined_no_sil/spk2utt > $data/voxceleb_train_combined_no_sil/utt2spk

  utils/filter_scp.pl $data/voxceleb_train_combined_no_sil/utt2spk $data/voxceleb_train_combined_no_sil/utt2num_frames > $data/voxceleb_train_combined_no_sil/utt2num_frames.new
  mv $data/voxceleb_train_combined_no_sil/utt2num_frames.new $data/voxceleb_train_combined_no_sil/utt2num_frames

  # Now we're ready to create training examples.
  utils/fix_data_dir.sh $data/voxceleb_train_combined_no_sil
fi

if [ $stage -le 6 ]; then
  # Split the validation set
  num_heldout_spks=64
  num_heldout_utts_per_spk=20
  mkdir -p $data/voxceleb_train_combined_no_sil/train2/ $data/voxceleb_train_combined_no_sil/valid2/

  sed 's/-noise//' $data/voxceleb_train_combined_no_sil/utt2spk | sed 's/-music//' | sed 's/-babble//' | sed 's/-reverb//' |\
    paste -d ' ' $data/voxceleb_train_combined_no_sil/utt2spk - | cut -d ' ' -f 1,3 > $data/voxceleb_train_combined_no_sil/utt2uniq

  utils/utt2spk_to_spk2utt.pl $data/voxceleb_train_combined_no_sil/utt2uniq > $data/voxceleb_train_combined_no_sil/uniq2utt
  cat $data/voxceleb_train_combined_no_sil/utt2spk | utils/apply_map.pl -f 1 $data/voxceleb_train_combined_no_sil/utt2uniq |\
    sort | uniq > $data/voxceleb_train_combined_no_sil/utt2spk.uniq

  utils/utt2spk_to_spk2utt.pl $data/voxceleb_train_combined_no_sil/utt2spk.uniq > $data/voxceleb_train_combined_no_sil/spk2utt.uniq
  python $TF_KALDI_ROOT/misc/tools/sample_validset_spk2utt.py $num_heldout_spks $num_heldout_utts_per_spk $data/voxceleb_train_combined_no_sil/spk2utt.uniq > $data/voxceleb_train_combined_no_sil/valid2/spk2utt.uniq

  cat $data/voxceleb_train_combined_no_sil/valid2/spk2utt.uniq | utils/apply_map.pl -f 2- $data/voxceleb_train_combined_no_sil/uniq2utt > $data/voxceleb_train_combined_no_sil/valid2/spk2utt
  utils/spk2utt_to_utt2spk.pl $data/voxceleb_train_combined_no_sil/valid2/spk2utt > $data/voxceleb_train_combined_no_sil/valid2/utt2spk
  cp $data/voxceleb_train_combined_no_sil/feats.scp $data/voxceleb_train_combined_no_sil/valid2
  utils/filter_scp.pl $data/voxceleb_train_combined_no_sil/valid2/utt2spk $data/voxceleb_train_combined_no_sil/utt2num_frames > $data/voxceleb_train_combined_no_sil/valid2/utt2num_frames
  utils/fix_data_dir.sh $data/voxceleb_train_combined_no_sil/valid2

  utils/filter_scp.pl --exclude $data/voxceleb_train_combined_no_sil/valid2/utt2spk $data/voxceleb_train_combined_no_sil/utt2spk > $data/voxceleb_train_combined_no_sil/train2/utt2spk
  utils/utt2spk_to_spk2utt.pl $data/voxceleb_train_combined_no_sil/train2/utt2spk > $data/voxceleb_train_combined_no_sil/train2/spk2utt
  cp $data/voxceleb_train_combined_no_sil/feats.scp $data/voxceleb_train_combined_no_sil/train2
  utils/filter_scp.pl $data/voxceleb_train_combined_no_sil/train2/utt2spk $data/voxceleb_train_combined_no_sil/utt2num_frames > $data/voxceleb_train_combined_no_sil/train2/utt2num_frames
  utils/fix_data_dir.sh $data/voxceleb_train_combined_no_sil/train2

  awk -v id=0 '{print $1, id++}' $data/voxceleb_train_combined_no_sil/train2/spk2utt > $data/voxceleb_train_combined_no_sil/train2/spklist
exit 1
fi


if [ $stage -le 7 ]; then
## Training a softmax network
#nnetdir=$exp/xvector_nnet_tdnn_softmax_1e-2
#nnet/run_train_nnet.sh --cmd "$cuda_cmd" --env tf_gpu --continue-training false nnet_conf/tdnn_softmax_1e-2.json \
#    $data/voxceleb_train_combined_no_sil/train $data/voxceleb_train_combined_no_sil/train/spklist \
#    $data/voxceleb_train_combined_no_sil/softmax_valid $data/voxceleb_train_combined_no_sil/train/spklist \
#    $nnetdir
#
#
## ASoftmax
#nnetdir=$exp/xvector_nnet_tdnn_asoftmax_m1_linear_bn_1e-2
#nnet/run_train_nnet.sh --cmd "$cuda_cmd" --env tf_gpu --continue-training false nnet_conf/tdnn_asoftmax_m1_linear_bn_1e-2.json \
#    $data/voxceleb_train_combined_no_sil/train $data/voxceleb_train_combined_no_sil/train/spklist \
#    $data/voxceleb_train_combined_no_sil/softmax_valid $data/voxceleb_train_combined_no_sil/train/spklist \
#    $nnetdir
#
#nnetdir=$exp/xvector_nnet_tdnn_asoftmax_m2_linear_bn_1e-2
#nnet/run_train_nnet.sh --cmd "$cuda_cmd" --env tf_gpu --continue-training false nnet_conf/tdnn_asoftmax_m2_linear_bn_1e-2.json \
#    $data/voxceleb_train_combined_no_sil/train $data/voxceleb_train_combined_no_sil/train/spklist \
#    $data/voxceleb_train_combined_no_sil/softmax_valid $data/voxceleb_train_combined_no_sil/train/spklist \
#    $nnetdir
#
nnetdir=$exp/xvector_nnet_tdnn_asoftmax_m4_linear_bn_1e-2
nnet/run_train_nnet_kftdnn_mgpu.sh --cmd "$cuda_cmd" --env tf_2_gpu --continue-training false nnet_conf/ftdnn2_asoftmax_m4_linear_bn_1e-2.json \
    $data/voxceleb_train_combined_no_sil/train2 $data/voxceleb_train_combined_no_sil/train2/spklist \
    $data/voxceleb_train_combined_no_sil/valid2 $data/voxceleb_train_combined_no_sil/train2/spklist \
    $nnetdir
#
#
## Additive margin softmax
#nnetdir=$exp/xvector_nnet_tdnn_amsoftmax_m0.15_linear_bn_1e-2
#nnet/run_train_nnet.sh --cmd "$cuda_cmd" --env tf_gpu --continue-training false nnet_conf/tdnn_amsoftmax_m0.15_linear_bn_1e-2.json \
#    $data/voxceleb_train_combined_no_sil/train $data/voxceleb_train_combined_no_sil/train/spklist \
#    $data/voxceleb_train_combined_no_sil/softmax_valid $data/voxceleb_train_combined_no_sil/train/spklist \
#    $nnetdir
#
#nnetdir=$exp/xvector_nnet_tdnn_amsoftmax_m0.20_linear_bn_1e-2
#nnet/run_train_nnet.sh --cmd "$cuda_cmd" --env tf_gpu --continue-training false nnet_conf/tdnn_amsoftmax_m0.20_linear_bn_1e-2.json \
#    $data/voxceleb_train_combined_no_sil/train $data/voxceleb_train_combined_no_sil/train/spklist \
#    $data/voxceleb_train_combined_no_sil/softmax_valid $data/voxceleb_train_combined_no_sil/train/spklist \
#    $nnetdir
#
#nnetdir=$exp/xvector_nnet_tdnn_amsoftmax_m0.25_linear_bn_1e-2
#nnet/run_train_nnet.sh --cmd "$cuda_cmd" --env tf_gpu --continue-training false nnet_conf/tdnn_amsoftmax_m0.25_linear_bn_1e-2.json \
#    $data/voxceleb_train_combined_no_sil/train $data/voxceleb_train_combined_no_sil/train/spklist \
#    $data/voxceleb_train_combined_no_sil/softmax_valid $data/voxceleb_train_combined_no_sil/train/spklist \
#    $nnetdir
#
#nnetdir=$exp/xvector_nnet_tdnn_amsoftmax_m0.30_linear_bn_1e-2
#nnet/run_train_nnet.sh --cmd "$cuda_cmd" --env tf_gpu --continue-training false nnet_conf/tdnn_amsoftmax_m0.30_linear_bn_1e-2.json \
#    $data/voxceleb_train_combined_no_sil/train $data/voxceleb_train_combined_no_sil/train/spklist \
#    $data/voxceleb_train_combined_no_sil/softmax_valid $data/voxceleb_train_combined_no_sil/train/spklist \
#    $nnetdir
#
#nnetdir=$exp/xvector_nnet_tdnn_amsoftmax_m0.35_linear_bn_1e-2
#nnet/run_train_nnet.sh --cmd "$cuda_cmd" --env tf_gpu --continue-training false nnet_conf/tdnn_amsoftmax_m0.35_linear_bn_1e-2.json \
#    $data/voxceleb_train_combined_no_sil/train $data/voxceleb_train_combined_no_sil/train/spklist \
#    $data/voxceleb_train_combined_no_sil/softmax_valid $data/voxceleb_train_combined_no_sil/train/spklist \
#    $nnetdir
#
## ArcSoftmax
#nnetdir=$exp/xvector_nnet_tdnn_arcsoftmax_m0.15_linear_bn_1e-2
#nnet/run_train_nnet.sh --cmd "$cuda_cmd" --env tf_gpu --continue-training false nnet_conf/tdnn_arcsoftmax_m0.15_linear_bn_1e-2.json \
#    $data/voxceleb_train_combined_no_sil/train $data/voxceleb_train_combined_no_sil/train/spklist \
#    $data/voxceleb_train_combined_no_sil/softmax_valid $data/voxceleb_train_combined_no_sil/train/spklist \
#    $nnetdir
#
#nnetdir=$exp/xvector_nnet_tdnn_arcsoftmax_m0.20_linear_bn_1e-2
#nnet/run_train_nnet.sh --cmd "$cuda_cmd" --env tf_gpu --continue-training false nnet_conf/tdnn_arcsoftmax_m0.20_linear_bn_1e-2.json \
#    $data/voxceleb_train_combined_no_sil/train $data/voxceleb_train_combined_no_sil/train/spklist \
#    $data/voxceleb_train_combined_no_sil/softmax_valid $data/voxceleb_train_combined_no_sil/train/spklist \
#    $nnetdir
#
#nnetdir=$exp/xvector_nnet_tdnn_arcsoftmax_m0.25_linear_bn_1e-2
#nnet/run_train_nnet.sh --cmd "$cuda_cmd" --env tf_gpu --continue-training false nnet_conf/tdnn_arcsoftmax_m0.25_linear_bn_1e-2.json \
#    $data/voxceleb_train_combined_no_sil/train $data/voxceleb_train_combined_no_sil/train/spklist \
#    $data/voxceleb_train_combined_no_sil/softmax_valid $data/voxceleb_train_combined_no_sil/train/spklist \
#    $nnetdir
#
#nnetdir=$exp/xvector_nnet_tdnn_arcsoftmax_m0.30_linear_bn_1e-2
#nnet/run_train_nnet.sh --cmd "$cuda_cmd" --env tf_gpu --continue-training false nnet_conf/tdnn_arcsoftmax_m0.30_linear_bn_1e-2.json \
#    $data/voxceleb_train_combined_no_sil/train $data/voxceleb_train_combined_no_sil/train/spklist \
#    $data/voxceleb_train_combined_no_sil/softmax_valid $data/voxceleb_train_combined_no_sil/train/spklist \
#    $nnetdir
#
#nnetdir=$exp/xvector_nnet_tdnn_arcsoftmax_m0.35_linear_bn_1e-2
#nnet/run_train_nnet.sh --cmd "$cuda_cmd" --env tf_gpu --continue-training false nnet_conf/tdnn_arcsoftmax_m0.35_linear_bn_1e-2.json \
#    $data/voxceleb_train_combined_no_sil/train $data/voxceleb_train_combined_no_sil/train/spklist \
#    $data/voxceleb_train_combined_no_sil/softmax_valid $data/voxceleb_train_combined_no_sil/train/spklist \
#    $nnetdir
#
#nnetdir=$exp/xvector_nnet_tdnn_arcsoftmax_m0.40_linear_bn_1e-2
#nnet/run_train_nnet.sh --cmd "$cuda_cmd" --env tf_gpu --continue-training false nnet_conf/tdnn_arcsoftmax_m0.40_linear_bn_1e-2.json \
#    $data/voxceleb_train_combined_no_sil/train $data/voxceleb_train_combined_no_sil/train/spklist \
#    $data/voxceleb_train_combined_no_sil/softmax_valid $data/voxceleb_train_combined_no_sil/train/spklist \
#    $nnetdir


## Add "Ring Loss"
#nnetdir=$exp/xvector_nnet_tdnn_amsoftmax_m0.20_linear_bn_1e-2_r0.01
#nnet/run_train_nnet.sh --cmd "$cuda_cmd" --env tf_gpu --continue-training false nnet_conf/tdnn_amsoftmax_m0.20_linear_bn_1e-2_r0.01.json \
#    $data/voxceleb_train_combined_no_sil/train $data/voxceleb_train_combined_no_sil/train/spklist \
#    $data/voxceleb_train_combined_no_sil/softmax_valid $data/voxceleb_train_combined_no_sil/train/spklist \
#    $nnetdir

#nnetdir=$exp/xvector_nnet_tdnn_amsoftmax_m0.20_linear_bn_fn30_1e-2
#nnet/run_train_nnet.sh --cmd "$cuda_cmd" --env tf_gpu --continue-training false nnet_conf/tdnn_amsoftmax_m0.20_linear_bn_fn30_1e-2.json \
#    $data/voxceleb_train_combined_no_sil/train $data/voxceleb_train_combined_no_sil/train/spklist \
#    $data/voxceleb_train_combined_no_sil/softmax_valid $data/voxceleb_train_combined_no_sil/train/spklist \
#    $nnetdir
#
## Add "MHE"
#nnetdir=$exp/xvector_nnet_tdnn_amsoftmax_m0.20_linear_bn_1e-2_mhe0.01
#nnet/run_train_nnet.sh --cmd "$cuda_cmd" --env tf_gpu --continue-training true nnet_conf/tdnn_amsoftmax_m0.20_linear_bn_1e-2_mhe0.01.json \
#    $data/voxceleb_train_combined_no_sil/train $data/voxceleb_train_combined_no_sil/train/spklist \
#    $data/voxceleb_train_combined_no_sil/softmax_valid $data/voxceleb_train_combined_no_sil/train/spklist \
#    $nnetdir


# Add attention
# nnetdir=$exp/xvector_nnet_tdnn_amsoftmax_m0.20_linear_bn_1e-2_tdnn4_att
# nnet/run_train_nnet.sh --cmd "$cuda_cmd" --env tf_gpu --continue-training false nnet_conf/tdnn_amsoftmax_m0.20_linear_bn_1e-2_tdnn4_att.json \
#     $data/voxceleb_train_combined_no_sil/train $data/voxceleb_train_combined_no_sil/train/spklist \
#     $data/voxceleb_train_combined_no_sil/softmax_valid $data/voxceleb_train_combined_no_sil/train/spklist \
#     $nnetdir


exit 1
echo
fi


#nnetdir=$exp/xvector_nnet_tdnn_e2e_m0.1_linear_bn_1e-4
nnetdir=$exp/xvector_nnet_tdnn_asoftmax_m4_linear_bn_1e-2
checkpoint='last'

if [ $stage -le 8 ]; then
  # Extract the embeddings
#   nnet/run_extract_embeddings.sh --cmd "$train_cmd" --nj 80 --use-gpu false --checkpoint $checkpoint --stage 0 \
#     --chunk-size 10000 --normalize false --node "tdnn6_dense" \
#     $nnetdir $data/sre18_major $nnetdir/xvectors_sre18_major

#   nnet/run_extract_embeddings.sh --cmd "$train_cmd" --nj 40 --use-gpu false --checkpoint $checkpoint --stage 0 \
#     --chunk-size 10000 --normalize false --node "tdnn6_dense" \
#     $nnetdir $data/sre_18eval $nnetdir/xvectors_sre_combined

#  nnet/run_extract_embeddings.sh --cmd "$train_cmd" --nj 40 --use-gpu false --checkpoint $checkpoint --stage 0 \
#    --chunk-size 10000 --normalize false --node "tdnn6_dense" \
#    $nnetdir $data/sre18_eval_test $nnetdir/xvectors_sre18_eval_test
#  nnet/run_extract_embeddings.sh --cmd "$train_cmd" --nj 40 --use-gpu false --checkpoint $checkpoint --stage 0 \
#    --chunk-size 10000 --normalize false --node "tdnn6_dense" \
#    $nnetdir $data/sre18_eval_enroll $nnetdir/xvectors_sre18_eval_enroll
#  nnet/run_extract_embeddings.sh --cmd "$train_cmd" --nj 40 --use-gpu false --checkpoint $checkpoint --stage 0 \
#    --chunk-size 10000 --normalize false --node "tdnn6_dense" \
#    $nnetdir $data/sre18_dev_test $nnetdir/xvectors_sre18_dev_test
#  nnet/run_extract_embeddings.sh --cmd "$train_cmd" --nj 40 --use-gpu false --checkpoint $checkpoint --stage 0 \
#    --chunk-size 10000 --normalize false --node "tdnn6_dense" \
#    $nnetdir $data/sre18_dev_enroll $nnetdir/xvectors_sre18_dev_enroll
  nnet/run_extract_embeddings.sh --cmd "$train_cmd" --nj 40 --use-gpu false --checkpoint $checkpoint --stage 0 \
    --chunk-size 10000 --normalize false --node "tdnn6_dense" \
    $nnetdir $data/sre19_eval_test $nnetdir/xvectors_sre19_eval_test
  nnet/run_extract_embeddings.sh --cmd "$train_cmd" --nj 40 --use-gpu false --checkpoint $checkpoint --stage 0 \
    --chunk-size 10000 --normalize false --node "tdnn6_dense" \
    $nnetdir $data/sre19_eval_enroll $nnetdir/xvectors_sre19_eval_enroll
  exit
fi
exp=$nnetdir
if [ $stage -le 9 ]; then
  # Compute the mean vector for centering the evaluation xvectors.
 # $train_cmd $exp/xvectors_sre18_major/log/compute_mean.log \
 #   ivector-mean scp:$exp/xvectors_sre18_major/xvector.scp \
 #   $exp/xvectors_sre18_major/mean.vec || exit 1;

  # This script uses LDA to decrease the dimensionality prior to PLDA.
  lda_dim=150
  $train_cmd $exp/xvectors_sre_combined/log/lda.log \
    ivector-compute-lda --total-covariance-factor=0.0 --dim=$lda_dim \
    "ark:ivector-subtract-global-mean scp:${exp}/xvectors_sre_combined/xvector.scp ark:- |" \
    ark:data/sre_combined/utt2spk $exp/xvectors_sre_combined/transform.mat || exit 1;

  # Train an out-of-domain PLDA model.
  $train_cmd $exp/xvectors_sre_combined/log/plda.log \
    ivector-compute-plda ark:data/sre_combined/spk2utt \
    "ark:ivector-subtract-global-mean scp:$exp/xvectors_sre_combined/xvector.scp ark:- | transform-vec ${exp}/xvectors_sre_combined/transform.mat ark:- ark:- | ivector-normalize-length ark:-  ark:- |" \
    $exp/xvectors_sre_combined/plda || exit 1;

  # Here we adapt the out-of-domain PLDA model to SRE18 major, a pile
  # of unlabeled in-domain data.  In the future, we will include a clustering
  # based approach for domain adaptation, which tends to work better.
  $train_cmd $exp/xvectors_sre18_major/log/plda_adapt.log \
    ivector-adapt-plda --within-covar-scale=0.75 --between-covar-scale=0.25 \
    $exp/xvectors_sre_combined/plda \
    "ark:ivector-subtract-global-mean scp:${exp}/xvectors_sre18_major/xvector.scp ark:- | transform-vec ${exp}/xvectors_sre_combined/transform.mat ark:- ark:- | ivector-normalize-length ark:- ark:- |" \
    $exp/xvectors_sre18_major/plda_adapt || exit 1;
fi

if [ $stage -le 10 ]; then
  # Get sre18 dev results using the out-of-domain PLDA model.
  $train_cmd $exp/scores/log/sre18_dev_scoring.log \
    ivector-plda-scoring --normalize-length=true \
    --num-utts=ark:$exp/xvectors_sre18_dev_enroll/num_utts.ark \
    "ivector-copy-plda --smoothing=0.0 ${exp}/xvectors_sre_combined/plda - |" \
    "ark:ivector-mean ark:data/sre18_dev_enroll/spk2utt scp:${exp}/xvectors_sre18_dev_enroll/xvector.scp ark:- | ivector-subtract-global-mean ${exp}/xvectors_sre18_major/mean.vec ark:- ark:- | transform-vec ${exp}/xvectors_sre_combined/transform.mat ark:- ark:- | ivector-normalize-length ark:- ark:- |" \
    "ark:ivector-subtract-global-mean ${exp}/xvectors_sre18_major/mean.vec scp:${exp}/xvectors_sre18_dev_test/xvector.scp ark:- | transform-vec ${exp}/xvectors_sre_combined/transform.mat ark:- ark:- | ivector-normalize-length ark:- ark:- |" \
    "cat '$sre18_dev_trials' | cut -d\  --fields=1,2 |" $exp/scores/sre18_dev_scores || exit 1;

  pooled_eer=$(paste $sre18_dev_trials $exp/scores/sre18_dev_scores | awk '{print $6, $3}'   | compute-eer - 2>/dev/null)
  echo "SRE18 DEV Using Out-of-Domain PLDA, EER: Pooled ${pooled_eer}%"
fi

if [ $stage -le 11 ]; then
  # Get sre18 dev results using the adapted PLDA model.
  $train_cmd $exp/scores/log/sre18_dev_scoring_adapt.log \
    ivector-plda-scoring --normalize-length=true \
    --num-utts=ark:$exp/xvectors_sre18_dev_enroll/num_utts.ark \
    "ivector-copy-plda --smoothing=0.0 ${exp}/xvectors_sre18_major/plda_adapt - |" \
    "ark:ivector-mean ark:data/sre18_dev_enroll/spk2utt scp:${exp}/xvectors_sre18_dev_enroll/xvector.scp ark:- | ivector-subtract-global-mean ${exp}/xvectors_sre18_major/mean.vec ark:- ark:- | transform-vec ${exp}/xvectors_sre_combined/transform.mat ark:- ark:- | ivector-normalize-length ark:- ark:- |" \
    "ark:ivector-subtract-global-mean ${exp}/xvectors_sre18_major/mean.vec scp:${exp}/xvectors_sre18_dev_test/xvector.scp ark:- | transform-vec ${exp}/xvectors_sre_combined/transform.mat ark:- ark:- | ivector-normalize-length ark:- ark:- |" \
    "cat '$sre18_dev_trials' | cut -d\  --fields=1,2 |" $exp/scores/sre18_dev_scores_adapt   || exit 1;

  pooled_eer=$(paste $sre18_dev_trials $exp/scores/sre18_dev_scores_adapt | awk '{print $6,  $3}' | compute-eer - 2>/dev/null)
  echo "SRE18 DEV Using Adapted PLDA, EER: Pooled ${pooled_eer}%"
fi

if [ $stage -le 12 ]; then
  # Get sre18 eval results using the out-of-domain PLDA model.
  $train_cmd exp/scores/log/sre18_eval_scoring.log \
    ivector-plda-scoring --normalize-length=true \
    --num-utts=ark:exp/xvectors_sre18_eval_enroll/num_utts.ark \
    "ivector-copy-plda --smoothing=0.0 exp/xvectors_sre_combined/plda - |" \
    "ark:ivector-mean ark:data/sre18_eval_enroll/spk2utt scp:exp/                           xvectors_sre18_eval_enroll/xvector.scp ark:- | ivector-subtract-global-mean exp/            xvectors_sre18_major/mean.vec ark:- ark:- | transform-vec exp/xvectors_sre_combined/        transform.mat ark:- ark:- | ivector-normalize-length ark:- ark:- |" \
    "ark:ivector-subtract-global-mean exp/xvectors_sre18_major/mean.vec scp:exp/            xvectors_sre18_eval_test/xvector.scp ark:- | transform-vec exp/xvectors_sre_combined/       transform.mat ark:- ark:- | ivector-normalize-length ark:- ark:- |" \
    "cat '$sre18_eval_trials' | cut -d\  --fields=1,2 |" exp/scores/sre18_eval_scores ||    exit 1;

  pooled_eer=$(paste $sre18_eval_trials exp/scores/sre18_eval_scores | awk '{print $6,      $3}' | compute-eer - 2>/dev/null)
  echo "SRE18 EVAL Using Out-of-Domain PLDA, EER: Pooled ${pooled_eer}%"
fi

if [ $stage -le 13 ]; then
  # Get sre18 eval results using the adapted PLDA model.
  $train_cmd exp/scores/log/sre18_eval_scoring_adapt.log \
    ivector-plda-scoring --normalize-length=true \
    --num-utts=ark:exp/xvectors_sre18_eval_enroll/num_utts.ark \
    "ivector-copy-plda --smoothing=0.0 exp/xvectors_sre18_major/plda_adapt - |" \
    "ark:ivector-mean ark:data/sre18_eval_enroll/spk2utt scp:exp/                           xvectors_sre18_eval_enroll/xvector.scp ark:- | ivector-subtract-global-mean exp/            xvectors_sre18_major/mean.vec ark:- ark:- | transform-vec exp/xvectors_sre_combined/        transform.mat ark:- ark:- | ivector-normalize-length ark:- ark:- |" \
    "ark:ivector-subtract-global-mean exp/xvectors_sre18_major/mean.vec scp:exp/            xvectors_sre18_eval_test/xvector.scp ark:- | transform-vec exp/xvectors_sre_combined/       transform.mat ark:- ark:- | ivector-normalize-length ark:- ark:- |" \
    "cat '$sre18_eval_trials' | cut -d\  --fields=1,2 |" exp/scores/                        sre18_eval_scores_adapt || exit 1;

  pooled_eer=$(paste $sre18_eval_trials exp/scores/sre18_eval_scores_adapt | awk '{print    $6, $3}' | compute-eer - 2>/dev/null)
  echo "SRE18 EVAL Using Adapted PLDA, EER: Pooled ${pooled_eer}%"
fi

if [ $stage -le 14 ]; then
  # Get sre19 eval results using the out-of-domain PLDA model.
  $train_cmd exp/scores/log/sre19_eval_scoring.log \
    ivector-plda-scoring --normalize-length=true \
    --num-utts=ark:exp/xvectors_sre19_eval_enroll/num_utts.ark \
    "ivector-copy-plda --smoothing=0.0 exp/xvectors_sre_combined/plda - |" \
    "ark:ivector-mean ark:data/sre19_eval_enroll/spk2utt scp:exp/xvectors_sre19_eval_enroll/xvector.scp ark:- | ivector-         subtract-global-mean exp/xvectors_sre18_major/mean.vec ark:- ark:- | transform-vec exp/xvectors_sre_combined/transform.mat       ark:- ark:- | ivector-normalize-length ark:- ark:- |" \
    "ark:ivector-subtract-global-mean exp/xvectors_sre18_major/mean.vec scp:exp/xvectors_sre19_eval_test/xvector.scp ark:- |     transform-vec exp/xvectors_sre_combined/transform.mat ark:- ark:- | ivector-normalize-length ark:- ark:- |" \
    "cat '$sre19_eval_trials' | cut -d\  --fields=1,2 |" exp/scores/sre19_eval_scores || exit 1;

  pooled_eer=$(paste $sre19_eval_trials exp/scores/sre19_eval_scores | awk '{print $6, $3}' | compute-eer - 2>/dev/null)
  echo "SRE19 EVAL Using Out-of-Domain PLDA, EER: Pooled ${pooled_eer}%"
fi

if [ $stage -le 15 ]; then
  # Get sre18 eval results using the adapted PLDA model.
  $train_cmd exp/scores/log/sre19_eval_scoring_adapt.log \
    ivector-plda-scoring --normalize-length=true \
    --num-utts=ark:exp/xvectors_sre19_eval_enroll/num_utts.ark \
    "ivector-copy-plda --smoothing=0.0 exp/xvectors_sre18_major/plda_adapt - |" \
    "ark:ivector-mean ark:data/sre19_eval_enroll/spk2utt scp:exp/xvectors_sre19_eval_enroll/xvector.scp ark:- | ivector-         subtract-global-mean exp/xvectors_sre18_major/mean.vec ark:- ark:- | transform-vec exp/xvectors_sre_combined/transform.mat       ark:- ark:- | ivector-normalize-length ark:- ark:- |" \
    "ark:ivector-subtract-global-mean exp/xvectors_sre18_major/mean.vec scp:exp/xvectors_sre19_eval_test/xvector.scp ark:- |     transform-vec exp/xvectors_sre_combined/transform.mat ark:- ark:- | ivector-normalize-length ark:- ark:- |" \
    "cat '$sre19_eval_trials' | cut -d\  --fields=1,2 |" exp/scores/sre19_eval_scores_adapt || exit 1;

  pooled_eer=$(paste $sre19_eval_trials exp/scores/sre19_eval_scores_adapt | awk '{print $6, $3}' | compute-eer - 2>/dev/null)
  echo "SRE19 EVAL Using Adapted PLDA, EER: Pooled ${pooled_eer}%"
fi