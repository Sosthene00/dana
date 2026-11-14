// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'frigate_event.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

T _$identity<T>(T value) => value;

final _privateConstructorUsedError = UnsupportedError(
    'It seems like you constructed your class using `MyClass._()`. This constructor is only meant to be used by freezed and you are not supposed to need it nor use it.\nPlease check the documentation here for more information: https://github.com/rrousselGit/freezed#adding-getters-and-methods-to-our-models');

/// @nodoc
mixin _$FrigateEventDto {
  @optionalTypeArgs
  TResult when<TResult extends Object?>({
    required TResult Function(int height, String hash) tip,
    required TResult Function(
            int blkheight, String blkhash, List<OwnedOutput> foundOutputs)
        confirmed,
    required TResult Function(String txid, List<OwnedOutput> outputs)
        unconfirmed,
    required TResult Function() caughtUp,
    required TResult Function(List<OutPoint> outpoints) spent,
    required TResult Function(String reason) disconnected,
  }) =>
      throw _privateConstructorUsedError;
  @optionalTypeArgs
  TResult? whenOrNull<TResult extends Object?>({
    TResult? Function(int height, String hash)? tip,
    TResult? Function(
            int blkheight, String blkhash, List<OwnedOutput> foundOutputs)?
        confirmed,
    TResult? Function(String txid, List<OwnedOutput> outputs)? unconfirmed,
    TResult? Function()? caughtUp,
    TResult? Function(List<OutPoint> outpoints)? spent,
    TResult? Function(String reason)? disconnected,
  }) =>
      throw _privateConstructorUsedError;
  @optionalTypeArgs
  TResult maybeWhen<TResult extends Object?>({
    TResult Function(int height, String hash)? tip,
    TResult Function(
            int blkheight, String blkhash, List<OwnedOutput> foundOutputs)?
        confirmed,
    TResult Function(String txid, List<OwnedOutput> outputs)? unconfirmed,
    TResult Function()? caughtUp,
    TResult Function(List<OutPoint> outpoints)? spent,
    TResult Function(String reason)? disconnected,
    required TResult orElse(),
  }) =>
      throw _privateConstructorUsedError;
  @optionalTypeArgs
  TResult map<TResult extends Object?>({
    required TResult Function(FrigateEventDto_Tip value) tip,
    required TResult Function(FrigateEventDto_Confirmed value) confirmed,
    required TResult Function(FrigateEventDto_Unconfirmed value) unconfirmed,
    required TResult Function(FrigateEventDto_CaughtUp value) caughtUp,
    required TResult Function(FrigateEventDto_Spent value) spent,
    required TResult Function(FrigateEventDto_Disconnected value) disconnected,
  }) =>
      throw _privateConstructorUsedError;
  @optionalTypeArgs
  TResult? mapOrNull<TResult extends Object?>({
    TResult? Function(FrigateEventDto_Tip value)? tip,
    TResult? Function(FrigateEventDto_Confirmed value)? confirmed,
    TResult? Function(FrigateEventDto_Unconfirmed value)? unconfirmed,
    TResult? Function(FrigateEventDto_CaughtUp value)? caughtUp,
    TResult? Function(FrigateEventDto_Spent value)? spent,
    TResult? Function(FrigateEventDto_Disconnected value)? disconnected,
  }) =>
      throw _privateConstructorUsedError;
  @optionalTypeArgs
  TResult maybeMap<TResult extends Object?>({
    TResult Function(FrigateEventDto_Tip value)? tip,
    TResult Function(FrigateEventDto_Confirmed value)? confirmed,
    TResult Function(FrigateEventDto_Unconfirmed value)? unconfirmed,
    TResult Function(FrigateEventDto_CaughtUp value)? caughtUp,
    TResult Function(FrigateEventDto_Spent value)? spent,
    TResult Function(FrigateEventDto_Disconnected value)? disconnected,
    required TResult orElse(),
  }) =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $FrigateEventDtoCopyWith<$Res> {
  factory $FrigateEventDtoCopyWith(
          FrigateEventDto value, $Res Function(FrigateEventDto) then) =
      _$FrigateEventDtoCopyWithImpl<$Res, FrigateEventDto>;
}

/// @nodoc
class _$FrigateEventDtoCopyWithImpl<$Res, $Val extends FrigateEventDto>
    implements $FrigateEventDtoCopyWith<$Res> {
  _$FrigateEventDtoCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  /// Create a copy of FrigateEventDto
  /// with the given fields replaced by the non-null parameter values.
}

/// @nodoc
abstract class _$$FrigateEventDto_TipImplCopyWith<$Res> {
  factory _$$FrigateEventDto_TipImplCopyWith(_$FrigateEventDto_TipImpl value,
          $Res Function(_$FrigateEventDto_TipImpl) then) =
      __$$FrigateEventDto_TipImplCopyWithImpl<$Res>;
  @useResult
  $Res call({int height, String hash});
}

/// @nodoc
class __$$FrigateEventDto_TipImplCopyWithImpl<$Res>
    extends _$FrigateEventDtoCopyWithImpl<$Res, _$FrigateEventDto_TipImpl>
    implements _$$FrigateEventDto_TipImplCopyWith<$Res> {
  __$$FrigateEventDto_TipImplCopyWithImpl(_$FrigateEventDto_TipImpl _value,
      $Res Function(_$FrigateEventDto_TipImpl) _then)
      : super(_value, _then);

  /// Create a copy of FrigateEventDto
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? height = null,
    Object? hash = null,
  }) {
    return _then(_$FrigateEventDto_TipImpl(
      height: null == height
          ? _value.height
          : height // ignore: cast_nullable_to_non_nullable
              as int,
      hash: null == hash
          ? _value.hash
          : hash // ignore: cast_nullable_to_non_nullable
              as String,
    ));
  }
}

/// @nodoc

class _$FrigateEventDto_TipImpl extends FrigateEventDto_Tip {
  const _$FrigateEventDto_TipImpl({required this.height, required this.hash})
      : super._();

  @override
  final int height;
  @override
  final String hash;

  @override
  String toString() {
    return 'FrigateEventDto.tip(height: $height, hash: $hash)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$FrigateEventDto_TipImpl &&
            (identical(other.height, height) || other.height == height) &&
            (identical(other.hash, hash) || other.hash == hash));
  }

  @override
  int get hashCode => Object.hash(runtimeType, height, hash);

  /// Create a copy of FrigateEventDto
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  @pragma('vm:prefer-inline')
  _$$FrigateEventDto_TipImplCopyWith<_$FrigateEventDto_TipImpl> get copyWith =>
      __$$FrigateEventDto_TipImplCopyWithImpl<_$FrigateEventDto_TipImpl>(
          this, _$identity);

  @override
  @optionalTypeArgs
  TResult when<TResult extends Object?>({
    required TResult Function(int height, String hash) tip,
    required TResult Function(
            int blkheight, String blkhash, List<OwnedOutput> foundOutputs)
        confirmed,
    required TResult Function(String txid, List<OwnedOutput> outputs)
        unconfirmed,
    required TResult Function() caughtUp,
    required TResult Function(List<OutPoint> outpoints) spent,
    required TResult Function(String reason) disconnected,
  }) {
    return tip(height, hash);
  }

  @override
  @optionalTypeArgs
  TResult? whenOrNull<TResult extends Object?>({
    TResult? Function(int height, String hash)? tip,
    TResult? Function(
            int blkheight, String blkhash, List<OwnedOutput> foundOutputs)?
        confirmed,
    TResult? Function(String txid, List<OwnedOutput> outputs)? unconfirmed,
    TResult? Function()? caughtUp,
    TResult? Function(List<OutPoint> outpoints)? spent,
    TResult? Function(String reason)? disconnected,
  }) {
    return tip?.call(height, hash);
  }

  @override
  @optionalTypeArgs
  TResult maybeWhen<TResult extends Object?>({
    TResult Function(int height, String hash)? tip,
    TResult Function(
            int blkheight, String blkhash, List<OwnedOutput> foundOutputs)?
        confirmed,
    TResult Function(String txid, List<OwnedOutput> outputs)? unconfirmed,
    TResult Function()? caughtUp,
    TResult Function(List<OutPoint> outpoints)? spent,
    TResult Function(String reason)? disconnected,
    required TResult orElse(),
  }) {
    if (tip != null) {
      return tip(height, hash);
    }
    return orElse();
  }

  @override
  @optionalTypeArgs
  TResult map<TResult extends Object?>({
    required TResult Function(FrigateEventDto_Tip value) tip,
    required TResult Function(FrigateEventDto_Confirmed value) confirmed,
    required TResult Function(FrigateEventDto_Unconfirmed value) unconfirmed,
    required TResult Function(FrigateEventDto_CaughtUp value) caughtUp,
    required TResult Function(FrigateEventDto_Spent value) spent,
    required TResult Function(FrigateEventDto_Disconnected value) disconnected,
  }) {
    return tip(this);
  }

  @override
  @optionalTypeArgs
  TResult? mapOrNull<TResult extends Object?>({
    TResult? Function(FrigateEventDto_Tip value)? tip,
    TResult? Function(FrigateEventDto_Confirmed value)? confirmed,
    TResult? Function(FrigateEventDto_Unconfirmed value)? unconfirmed,
    TResult? Function(FrigateEventDto_CaughtUp value)? caughtUp,
    TResult? Function(FrigateEventDto_Spent value)? spent,
    TResult? Function(FrigateEventDto_Disconnected value)? disconnected,
  }) {
    return tip?.call(this);
  }

  @override
  @optionalTypeArgs
  TResult maybeMap<TResult extends Object?>({
    TResult Function(FrigateEventDto_Tip value)? tip,
    TResult Function(FrigateEventDto_Confirmed value)? confirmed,
    TResult Function(FrigateEventDto_Unconfirmed value)? unconfirmed,
    TResult Function(FrigateEventDto_CaughtUp value)? caughtUp,
    TResult Function(FrigateEventDto_Spent value)? spent,
    TResult Function(FrigateEventDto_Disconnected value)? disconnected,
    required TResult orElse(),
  }) {
    if (tip != null) {
      return tip(this);
    }
    return orElse();
  }
}

abstract class FrigateEventDto_Tip extends FrigateEventDto {
  const factory FrigateEventDto_Tip(
      {required final int height,
      required final String hash}) = _$FrigateEventDto_TipImpl;
  const FrigateEventDto_Tip._() : super._();

  int get height;
  String get hash;

  /// Create a copy of FrigateEventDto
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  _$$FrigateEventDto_TipImplCopyWith<_$FrigateEventDto_TipImpl> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class _$$FrigateEventDto_ConfirmedImplCopyWith<$Res> {
  factory _$$FrigateEventDto_ConfirmedImplCopyWith(
          _$FrigateEventDto_ConfirmedImpl value,
          $Res Function(_$FrigateEventDto_ConfirmedImpl) then) =
      __$$FrigateEventDto_ConfirmedImplCopyWithImpl<$Res>;
  @useResult
  $Res call({int blkheight, String blkhash, List<OwnedOutput> foundOutputs});
}

/// @nodoc
class __$$FrigateEventDto_ConfirmedImplCopyWithImpl<$Res>
    extends _$FrigateEventDtoCopyWithImpl<$Res, _$FrigateEventDto_ConfirmedImpl>
    implements _$$FrigateEventDto_ConfirmedImplCopyWith<$Res> {
  __$$FrigateEventDto_ConfirmedImplCopyWithImpl(
      _$FrigateEventDto_ConfirmedImpl _value,
      $Res Function(_$FrigateEventDto_ConfirmedImpl) _then)
      : super(_value, _then);

  /// Create a copy of FrigateEventDto
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? blkheight = null,
    Object? blkhash = null,
    Object? foundOutputs = null,
  }) {
    return _then(_$FrigateEventDto_ConfirmedImpl(
      blkheight: null == blkheight
          ? _value.blkheight
          : blkheight // ignore: cast_nullable_to_non_nullable
              as int,
      blkhash: null == blkhash
          ? _value.blkhash
          : blkhash // ignore: cast_nullable_to_non_nullable
              as String,
      foundOutputs: null == foundOutputs
          ? _value._foundOutputs
          : foundOutputs // ignore: cast_nullable_to_non_nullable
              as List<OwnedOutput>,
    ));
  }
}

/// @nodoc

class _$FrigateEventDto_ConfirmedImpl extends FrigateEventDto_Confirmed {
  const _$FrigateEventDto_ConfirmedImpl(
      {required this.blkheight,
      required this.blkhash,
      required final List<OwnedOutput> foundOutputs})
      : _foundOutputs = foundOutputs,
        super._();

  @override
  final int blkheight;
  @override
  final String blkhash;
  final List<OwnedOutput> _foundOutputs;
  @override
  List<OwnedOutput> get foundOutputs {
    if (_foundOutputs is EqualUnmodifiableListView) return _foundOutputs;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_foundOutputs);
  }

  @override
  String toString() {
    return 'FrigateEventDto.confirmed(blkheight: $blkheight, blkhash: $blkhash, foundOutputs: $foundOutputs)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$FrigateEventDto_ConfirmedImpl &&
            (identical(other.blkheight, blkheight) ||
                other.blkheight == blkheight) &&
            (identical(other.blkhash, blkhash) || other.blkhash == blkhash) &&
            const DeepCollectionEquality()
                .equals(other._foundOutputs, _foundOutputs));
  }

  @override
  int get hashCode => Object.hash(runtimeType, blkheight, blkhash,
      const DeepCollectionEquality().hash(_foundOutputs));

  /// Create a copy of FrigateEventDto
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  @pragma('vm:prefer-inline')
  _$$FrigateEventDto_ConfirmedImplCopyWith<_$FrigateEventDto_ConfirmedImpl>
      get copyWith => __$$FrigateEventDto_ConfirmedImplCopyWithImpl<
          _$FrigateEventDto_ConfirmedImpl>(this, _$identity);

  @override
  @optionalTypeArgs
  TResult when<TResult extends Object?>({
    required TResult Function(int height, String hash) tip,
    required TResult Function(
            int blkheight, String blkhash, List<OwnedOutput> foundOutputs)
        confirmed,
    required TResult Function(String txid, List<OwnedOutput> outputs)
        unconfirmed,
    required TResult Function() caughtUp,
    required TResult Function(List<OutPoint> outpoints) spent,
    required TResult Function(String reason) disconnected,
  }) {
    return confirmed(blkheight, blkhash, foundOutputs);
  }

  @override
  @optionalTypeArgs
  TResult? whenOrNull<TResult extends Object?>({
    TResult? Function(int height, String hash)? tip,
    TResult? Function(
            int blkheight, String blkhash, List<OwnedOutput> foundOutputs)?
        confirmed,
    TResult? Function(String txid, List<OwnedOutput> outputs)? unconfirmed,
    TResult? Function()? caughtUp,
    TResult? Function(List<OutPoint> outpoints)? spent,
    TResult? Function(String reason)? disconnected,
  }) {
    return confirmed?.call(blkheight, blkhash, foundOutputs);
  }

  @override
  @optionalTypeArgs
  TResult maybeWhen<TResult extends Object?>({
    TResult Function(int height, String hash)? tip,
    TResult Function(
            int blkheight, String blkhash, List<OwnedOutput> foundOutputs)?
        confirmed,
    TResult Function(String txid, List<OwnedOutput> outputs)? unconfirmed,
    TResult Function()? caughtUp,
    TResult Function(List<OutPoint> outpoints)? spent,
    TResult Function(String reason)? disconnected,
    required TResult orElse(),
  }) {
    if (confirmed != null) {
      return confirmed(blkheight, blkhash, foundOutputs);
    }
    return orElse();
  }

  @override
  @optionalTypeArgs
  TResult map<TResult extends Object?>({
    required TResult Function(FrigateEventDto_Tip value) tip,
    required TResult Function(FrigateEventDto_Confirmed value) confirmed,
    required TResult Function(FrigateEventDto_Unconfirmed value) unconfirmed,
    required TResult Function(FrigateEventDto_CaughtUp value) caughtUp,
    required TResult Function(FrigateEventDto_Spent value) spent,
    required TResult Function(FrigateEventDto_Disconnected value) disconnected,
  }) {
    return confirmed(this);
  }

  @override
  @optionalTypeArgs
  TResult? mapOrNull<TResult extends Object?>({
    TResult? Function(FrigateEventDto_Tip value)? tip,
    TResult? Function(FrigateEventDto_Confirmed value)? confirmed,
    TResult? Function(FrigateEventDto_Unconfirmed value)? unconfirmed,
    TResult? Function(FrigateEventDto_CaughtUp value)? caughtUp,
    TResult? Function(FrigateEventDto_Spent value)? spent,
    TResult? Function(FrigateEventDto_Disconnected value)? disconnected,
  }) {
    return confirmed?.call(this);
  }

  @override
  @optionalTypeArgs
  TResult maybeMap<TResult extends Object?>({
    TResult Function(FrigateEventDto_Tip value)? tip,
    TResult Function(FrigateEventDto_Confirmed value)? confirmed,
    TResult Function(FrigateEventDto_Unconfirmed value)? unconfirmed,
    TResult Function(FrigateEventDto_CaughtUp value)? caughtUp,
    TResult Function(FrigateEventDto_Spent value)? spent,
    TResult Function(FrigateEventDto_Disconnected value)? disconnected,
    required TResult orElse(),
  }) {
    if (confirmed != null) {
      return confirmed(this);
    }
    return orElse();
  }
}

abstract class FrigateEventDto_Confirmed extends FrigateEventDto {
  const factory FrigateEventDto_Confirmed(
          {required final int blkheight,
          required final String blkhash,
          required final List<OwnedOutput> foundOutputs}) =
      _$FrigateEventDto_ConfirmedImpl;
  const FrigateEventDto_Confirmed._() : super._();

  int get blkheight;
  String get blkhash;
  List<OwnedOutput> get foundOutputs;

  /// Create a copy of FrigateEventDto
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  _$$FrigateEventDto_ConfirmedImplCopyWith<_$FrigateEventDto_ConfirmedImpl>
      get copyWith => throw _privateConstructorUsedError;
}

/// @nodoc
abstract class _$$FrigateEventDto_UnconfirmedImplCopyWith<$Res> {
  factory _$$FrigateEventDto_UnconfirmedImplCopyWith(
          _$FrigateEventDto_UnconfirmedImpl value,
          $Res Function(_$FrigateEventDto_UnconfirmedImpl) then) =
      __$$FrigateEventDto_UnconfirmedImplCopyWithImpl<$Res>;
  @useResult
  $Res call({String txid, List<OwnedOutput> outputs});
}

/// @nodoc
class __$$FrigateEventDto_UnconfirmedImplCopyWithImpl<$Res>
    extends _$FrigateEventDtoCopyWithImpl<$Res,
        _$FrigateEventDto_UnconfirmedImpl>
    implements _$$FrigateEventDto_UnconfirmedImplCopyWith<$Res> {
  __$$FrigateEventDto_UnconfirmedImplCopyWithImpl(
      _$FrigateEventDto_UnconfirmedImpl _value,
      $Res Function(_$FrigateEventDto_UnconfirmedImpl) _then)
      : super(_value, _then);

  /// Create a copy of FrigateEventDto
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? txid = null,
    Object? outputs = null,
  }) {
    return _then(_$FrigateEventDto_UnconfirmedImpl(
      txid: null == txid
          ? _value.txid
          : txid // ignore: cast_nullable_to_non_nullable
              as String,
      outputs: null == outputs
          ? _value._outputs
          : outputs // ignore: cast_nullable_to_non_nullable
              as List<OwnedOutput>,
    ));
  }
}

/// @nodoc

class _$FrigateEventDto_UnconfirmedImpl extends FrigateEventDto_Unconfirmed {
  const _$FrigateEventDto_UnconfirmedImpl(
      {required this.txid, required final List<OwnedOutput> outputs})
      : _outputs = outputs,
        super._();

  @override
  final String txid;
  final List<OwnedOutput> _outputs;
  @override
  List<OwnedOutput> get outputs {
    if (_outputs is EqualUnmodifiableListView) return _outputs;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_outputs);
  }

  @override
  String toString() {
    return 'FrigateEventDto.unconfirmed(txid: $txid, outputs: $outputs)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$FrigateEventDto_UnconfirmedImpl &&
            (identical(other.txid, txid) || other.txid == txid) &&
            const DeepCollectionEquality().equals(other._outputs, _outputs));
  }

  @override
  int get hashCode => Object.hash(
      runtimeType, txid, const DeepCollectionEquality().hash(_outputs));

  /// Create a copy of FrigateEventDto
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  @pragma('vm:prefer-inline')
  _$$FrigateEventDto_UnconfirmedImplCopyWith<_$FrigateEventDto_UnconfirmedImpl>
      get copyWith => __$$FrigateEventDto_UnconfirmedImplCopyWithImpl<
          _$FrigateEventDto_UnconfirmedImpl>(this, _$identity);

  @override
  @optionalTypeArgs
  TResult when<TResult extends Object?>({
    required TResult Function(int height, String hash) tip,
    required TResult Function(
            int blkheight, String blkhash, List<OwnedOutput> foundOutputs)
        confirmed,
    required TResult Function(String txid, List<OwnedOutput> outputs)
        unconfirmed,
    required TResult Function() caughtUp,
    required TResult Function(List<OutPoint> outpoints) spent,
    required TResult Function(String reason) disconnected,
  }) {
    return unconfirmed(txid, outputs);
  }

  @override
  @optionalTypeArgs
  TResult? whenOrNull<TResult extends Object?>({
    TResult? Function(int height, String hash)? tip,
    TResult? Function(
            int blkheight, String blkhash, List<OwnedOutput> foundOutputs)?
        confirmed,
    TResult? Function(String txid, List<OwnedOutput> outputs)? unconfirmed,
    TResult? Function()? caughtUp,
    TResult? Function(List<OutPoint> outpoints)? spent,
    TResult? Function(String reason)? disconnected,
  }) {
    return unconfirmed?.call(txid, outputs);
  }

  @override
  @optionalTypeArgs
  TResult maybeWhen<TResult extends Object?>({
    TResult Function(int height, String hash)? tip,
    TResult Function(
            int blkheight, String blkhash, List<OwnedOutput> foundOutputs)?
        confirmed,
    TResult Function(String txid, List<OwnedOutput> outputs)? unconfirmed,
    TResult Function()? caughtUp,
    TResult Function(List<OutPoint> outpoints)? spent,
    TResult Function(String reason)? disconnected,
    required TResult orElse(),
  }) {
    if (unconfirmed != null) {
      return unconfirmed(txid, outputs);
    }
    return orElse();
  }

  @override
  @optionalTypeArgs
  TResult map<TResult extends Object?>({
    required TResult Function(FrigateEventDto_Tip value) tip,
    required TResult Function(FrigateEventDto_Confirmed value) confirmed,
    required TResult Function(FrigateEventDto_Unconfirmed value) unconfirmed,
    required TResult Function(FrigateEventDto_CaughtUp value) caughtUp,
    required TResult Function(FrigateEventDto_Spent value) spent,
    required TResult Function(FrigateEventDto_Disconnected value) disconnected,
  }) {
    return unconfirmed(this);
  }

  @override
  @optionalTypeArgs
  TResult? mapOrNull<TResult extends Object?>({
    TResult? Function(FrigateEventDto_Tip value)? tip,
    TResult? Function(FrigateEventDto_Confirmed value)? confirmed,
    TResult? Function(FrigateEventDto_Unconfirmed value)? unconfirmed,
    TResult? Function(FrigateEventDto_CaughtUp value)? caughtUp,
    TResult? Function(FrigateEventDto_Spent value)? spent,
    TResult? Function(FrigateEventDto_Disconnected value)? disconnected,
  }) {
    return unconfirmed?.call(this);
  }

  @override
  @optionalTypeArgs
  TResult maybeMap<TResult extends Object?>({
    TResult Function(FrigateEventDto_Tip value)? tip,
    TResult Function(FrigateEventDto_Confirmed value)? confirmed,
    TResult Function(FrigateEventDto_Unconfirmed value)? unconfirmed,
    TResult Function(FrigateEventDto_CaughtUp value)? caughtUp,
    TResult Function(FrigateEventDto_Spent value)? spent,
    TResult Function(FrigateEventDto_Disconnected value)? disconnected,
    required TResult orElse(),
  }) {
    if (unconfirmed != null) {
      return unconfirmed(this);
    }
    return orElse();
  }
}

abstract class FrigateEventDto_Unconfirmed extends FrigateEventDto {
  const factory FrigateEventDto_Unconfirmed(
          {required final String txid,
          required final List<OwnedOutput> outputs}) =
      _$FrigateEventDto_UnconfirmedImpl;
  const FrigateEventDto_Unconfirmed._() : super._();

  String get txid;
  List<OwnedOutput> get outputs;

  /// Create a copy of FrigateEventDto
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  _$$FrigateEventDto_UnconfirmedImplCopyWith<_$FrigateEventDto_UnconfirmedImpl>
      get copyWith => throw _privateConstructorUsedError;
}

/// @nodoc
abstract class _$$FrigateEventDto_CaughtUpImplCopyWith<$Res> {
  factory _$$FrigateEventDto_CaughtUpImplCopyWith(
          _$FrigateEventDto_CaughtUpImpl value,
          $Res Function(_$FrigateEventDto_CaughtUpImpl) then) =
      __$$FrigateEventDto_CaughtUpImplCopyWithImpl<$Res>;
}

/// @nodoc
class __$$FrigateEventDto_CaughtUpImplCopyWithImpl<$Res>
    extends _$FrigateEventDtoCopyWithImpl<$Res, _$FrigateEventDto_CaughtUpImpl>
    implements _$$FrigateEventDto_CaughtUpImplCopyWith<$Res> {
  __$$FrigateEventDto_CaughtUpImplCopyWithImpl(
      _$FrigateEventDto_CaughtUpImpl _value,
      $Res Function(_$FrigateEventDto_CaughtUpImpl) _then)
      : super(_value, _then);

  /// Create a copy of FrigateEventDto
  /// with the given fields replaced by the non-null parameter values.
}

/// @nodoc

class _$FrigateEventDto_CaughtUpImpl extends FrigateEventDto_CaughtUp {
  const _$FrigateEventDto_CaughtUpImpl() : super._();

  @override
  String toString() {
    return 'FrigateEventDto.caughtUp()';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$FrigateEventDto_CaughtUpImpl);
  }

  @override
  int get hashCode => runtimeType.hashCode;

  @override
  @optionalTypeArgs
  TResult when<TResult extends Object?>({
    required TResult Function(int height, String hash) tip,
    required TResult Function(
            int blkheight, String blkhash, List<OwnedOutput> foundOutputs)
        confirmed,
    required TResult Function(String txid, List<OwnedOutput> outputs)
        unconfirmed,
    required TResult Function() caughtUp,
    required TResult Function(List<OutPoint> outpoints) spent,
    required TResult Function(String reason) disconnected,
  }) {
    return caughtUp();
  }

  @override
  @optionalTypeArgs
  TResult? whenOrNull<TResult extends Object?>({
    TResult? Function(int height, String hash)? tip,
    TResult? Function(
            int blkheight, String blkhash, List<OwnedOutput> foundOutputs)?
        confirmed,
    TResult? Function(String txid, List<OwnedOutput> outputs)? unconfirmed,
    TResult? Function()? caughtUp,
    TResult? Function(List<OutPoint> outpoints)? spent,
    TResult? Function(String reason)? disconnected,
  }) {
    return caughtUp?.call();
  }

  @override
  @optionalTypeArgs
  TResult maybeWhen<TResult extends Object?>({
    TResult Function(int height, String hash)? tip,
    TResult Function(
            int blkheight, String blkhash, List<OwnedOutput> foundOutputs)?
        confirmed,
    TResult Function(String txid, List<OwnedOutput> outputs)? unconfirmed,
    TResult Function()? caughtUp,
    TResult Function(List<OutPoint> outpoints)? spent,
    TResult Function(String reason)? disconnected,
    required TResult orElse(),
  }) {
    if (caughtUp != null) {
      return caughtUp();
    }
    return orElse();
  }

  @override
  @optionalTypeArgs
  TResult map<TResult extends Object?>({
    required TResult Function(FrigateEventDto_Tip value) tip,
    required TResult Function(FrigateEventDto_Confirmed value) confirmed,
    required TResult Function(FrigateEventDto_Unconfirmed value) unconfirmed,
    required TResult Function(FrigateEventDto_CaughtUp value) caughtUp,
    required TResult Function(FrigateEventDto_Spent value) spent,
    required TResult Function(FrigateEventDto_Disconnected value) disconnected,
  }) {
    return caughtUp(this);
  }

  @override
  @optionalTypeArgs
  TResult? mapOrNull<TResult extends Object?>({
    TResult? Function(FrigateEventDto_Tip value)? tip,
    TResult? Function(FrigateEventDto_Confirmed value)? confirmed,
    TResult? Function(FrigateEventDto_Unconfirmed value)? unconfirmed,
    TResult? Function(FrigateEventDto_CaughtUp value)? caughtUp,
    TResult? Function(FrigateEventDto_Spent value)? spent,
    TResult? Function(FrigateEventDto_Disconnected value)? disconnected,
  }) {
    return caughtUp?.call(this);
  }

  @override
  @optionalTypeArgs
  TResult maybeMap<TResult extends Object?>({
    TResult Function(FrigateEventDto_Tip value)? tip,
    TResult Function(FrigateEventDto_Confirmed value)? confirmed,
    TResult Function(FrigateEventDto_Unconfirmed value)? unconfirmed,
    TResult Function(FrigateEventDto_CaughtUp value)? caughtUp,
    TResult Function(FrigateEventDto_Spent value)? spent,
    TResult Function(FrigateEventDto_Disconnected value)? disconnected,
    required TResult orElse(),
  }) {
    if (caughtUp != null) {
      return caughtUp(this);
    }
    return orElse();
  }
}

abstract class FrigateEventDto_CaughtUp extends FrigateEventDto {
  const factory FrigateEventDto_CaughtUp() = _$FrigateEventDto_CaughtUpImpl;
  const FrigateEventDto_CaughtUp._() : super._();
}

/// @nodoc
abstract class _$$FrigateEventDto_SpentImplCopyWith<$Res> {
  factory _$$FrigateEventDto_SpentImplCopyWith(
          _$FrigateEventDto_SpentImpl value,
          $Res Function(_$FrigateEventDto_SpentImpl) then) =
      __$$FrigateEventDto_SpentImplCopyWithImpl<$Res>;
  @useResult
  $Res call({List<OutPoint> outpoints});
}

/// @nodoc
class __$$FrigateEventDto_SpentImplCopyWithImpl<$Res>
    extends _$FrigateEventDtoCopyWithImpl<$Res, _$FrigateEventDto_SpentImpl>
    implements _$$FrigateEventDto_SpentImplCopyWith<$Res> {
  __$$FrigateEventDto_SpentImplCopyWithImpl(_$FrigateEventDto_SpentImpl _value,
      $Res Function(_$FrigateEventDto_SpentImpl) _then)
      : super(_value, _then);

  /// Create a copy of FrigateEventDto
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? outpoints = null,
  }) {
    return _then(_$FrigateEventDto_SpentImpl(
      outpoints: null == outpoints
          ? _value._outpoints
          : outpoints // ignore: cast_nullable_to_non_nullable
              as List<OutPoint>,
    ));
  }
}

/// @nodoc

class _$FrigateEventDto_SpentImpl extends FrigateEventDto_Spent {
  const _$FrigateEventDto_SpentImpl({required final List<OutPoint> outpoints})
      : _outpoints = outpoints,
        super._();

  final List<OutPoint> _outpoints;
  @override
  List<OutPoint> get outpoints {
    if (_outpoints is EqualUnmodifiableListView) return _outpoints;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_outpoints);
  }

  @override
  String toString() {
    return 'FrigateEventDto.spent(outpoints: $outpoints)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$FrigateEventDto_SpentImpl &&
            const DeepCollectionEquality()
                .equals(other._outpoints, _outpoints));
  }

  @override
  int get hashCode =>
      Object.hash(runtimeType, const DeepCollectionEquality().hash(_outpoints));

  /// Create a copy of FrigateEventDto
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  @pragma('vm:prefer-inline')
  _$$FrigateEventDto_SpentImplCopyWith<_$FrigateEventDto_SpentImpl>
      get copyWith => __$$FrigateEventDto_SpentImplCopyWithImpl<
          _$FrigateEventDto_SpentImpl>(this, _$identity);

  @override
  @optionalTypeArgs
  TResult when<TResult extends Object?>({
    required TResult Function(int height, String hash) tip,
    required TResult Function(
            int blkheight, String blkhash, List<OwnedOutput> foundOutputs)
        confirmed,
    required TResult Function(String txid, List<OwnedOutput> outputs)
        unconfirmed,
    required TResult Function() caughtUp,
    required TResult Function(List<OutPoint> outpoints) spent,
    required TResult Function(String reason) disconnected,
  }) {
    return spent(outpoints);
  }

  @override
  @optionalTypeArgs
  TResult? whenOrNull<TResult extends Object?>({
    TResult? Function(int height, String hash)? tip,
    TResult? Function(
            int blkheight, String blkhash, List<OwnedOutput> foundOutputs)?
        confirmed,
    TResult? Function(String txid, List<OwnedOutput> outputs)? unconfirmed,
    TResult? Function()? caughtUp,
    TResult? Function(List<OutPoint> outpoints)? spent,
    TResult? Function(String reason)? disconnected,
  }) {
    return spent?.call(outpoints);
  }

  @override
  @optionalTypeArgs
  TResult maybeWhen<TResult extends Object?>({
    TResult Function(int height, String hash)? tip,
    TResult Function(
            int blkheight, String blkhash, List<OwnedOutput> foundOutputs)?
        confirmed,
    TResult Function(String txid, List<OwnedOutput> outputs)? unconfirmed,
    TResult Function()? caughtUp,
    TResult Function(List<OutPoint> outpoints)? spent,
    TResult Function(String reason)? disconnected,
    required TResult orElse(),
  }) {
    if (spent != null) {
      return spent(outpoints);
    }
    return orElse();
  }

  @override
  @optionalTypeArgs
  TResult map<TResult extends Object?>({
    required TResult Function(FrigateEventDto_Tip value) tip,
    required TResult Function(FrigateEventDto_Confirmed value) confirmed,
    required TResult Function(FrigateEventDto_Unconfirmed value) unconfirmed,
    required TResult Function(FrigateEventDto_CaughtUp value) caughtUp,
    required TResult Function(FrigateEventDto_Spent value) spent,
    required TResult Function(FrigateEventDto_Disconnected value) disconnected,
  }) {
    return spent(this);
  }

  @override
  @optionalTypeArgs
  TResult? mapOrNull<TResult extends Object?>({
    TResult? Function(FrigateEventDto_Tip value)? tip,
    TResult? Function(FrigateEventDto_Confirmed value)? confirmed,
    TResult? Function(FrigateEventDto_Unconfirmed value)? unconfirmed,
    TResult? Function(FrigateEventDto_CaughtUp value)? caughtUp,
    TResult? Function(FrigateEventDto_Spent value)? spent,
    TResult? Function(FrigateEventDto_Disconnected value)? disconnected,
  }) {
    return spent?.call(this);
  }

  @override
  @optionalTypeArgs
  TResult maybeMap<TResult extends Object?>({
    TResult Function(FrigateEventDto_Tip value)? tip,
    TResult Function(FrigateEventDto_Confirmed value)? confirmed,
    TResult Function(FrigateEventDto_Unconfirmed value)? unconfirmed,
    TResult Function(FrigateEventDto_CaughtUp value)? caughtUp,
    TResult Function(FrigateEventDto_Spent value)? spent,
    TResult Function(FrigateEventDto_Disconnected value)? disconnected,
    required TResult orElse(),
  }) {
    if (spent != null) {
      return spent(this);
    }
    return orElse();
  }
}

abstract class FrigateEventDto_Spent extends FrigateEventDto {
  const factory FrigateEventDto_Spent(
      {required final List<OutPoint> outpoints}) = _$FrigateEventDto_SpentImpl;
  const FrigateEventDto_Spent._() : super._();

  List<OutPoint> get outpoints;

  /// Create a copy of FrigateEventDto
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  _$$FrigateEventDto_SpentImplCopyWith<_$FrigateEventDto_SpentImpl>
      get copyWith => throw _privateConstructorUsedError;
}

/// @nodoc
abstract class _$$FrigateEventDto_DisconnectedImplCopyWith<$Res> {
  factory _$$FrigateEventDto_DisconnectedImplCopyWith(
          _$FrigateEventDto_DisconnectedImpl value,
          $Res Function(_$FrigateEventDto_DisconnectedImpl) then) =
      __$$FrigateEventDto_DisconnectedImplCopyWithImpl<$Res>;
  @useResult
  $Res call({String reason});
}

/// @nodoc
class __$$FrigateEventDto_DisconnectedImplCopyWithImpl<$Res>
    extends _$FrigateEventDtoCopyWithImpl<$Res,
        _$FrigateEventDto_DisconnectedImpl>
    implements _$$FrigateEventDto_DisconnectedImplCopyWith<$Res> {
  __$$FrigateEventDto_DisconnectedImplCopyWithImpl(
      _$FrigateEventDto_DisconnectedImpl _value,
      $Res Function(_$FrigateEventDto_DisconnectedImpl) _then)
      : super(_value, _then);

  /// Create a copy of FrigateEventDto
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? reason = null,
  }) {
    return _then(_$FrigateEventDto_DisconnectedImpl(
      reason: null == reason
          ? _value.reason
          : reason // ignore: cast_nullable_to_non_nullable
              as String,
    ));
  }
}

/// @nodoc

class _$FrigateEventDto_DisconnectedImpl extends FrigateEventDto_Disconnected {
  const _$FrigateEventDto_DisconnectedImpl({required this.reason}) : super._();

  @override
  final String reason;

  @override
  String toString() {
    return 'FrigateEventDto.disconnected(reason: $reason)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$FrigateEventDto_DisconnectedImpl &&
            (identical(other.reason, reason) || other.reason == reason));
  }

  @override
  int get hashCode => Object.hash(runtimeType, reason);

  /// Create a copy of FrigateEventDto
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  @pragma('vm:prefer-inline')
  _$$FrigateEventDto_DisconnectedImplCopyWith<
          _$FrigateEventDto_DisconnectedImpl>
      get copyWith => __$$FrigateEventDto_DisconnectedImplCopyWithImpl<
          _$FrigateEventDto_DisconnectedImpl>(this, _$identity);

  @override
  @optionalTypeArgs
  TResult when<TResult extends Object?>({
    required TResult Function(int height, String hash) tip,
    required TResult Function(
            int blkheight, String blkhash, List<OwnedOutput> foundOutputs)
        confirmed,
    required TResult Function(String txid, List<OwnedOutput> outputs)
        unconfirmed,
    required TResult Function() caughtUp,
    required TResult Function(List<OutPoint> outpoints) spent,
    required TResult Function(String reason) disconnected,
  }) {
    return disconnected(reason);
  }

  @override
  @optionalTypeArgs
  TResult? whenOrNull<TResult extends Object?>({
    TResult? Function(int height, String hash)? tip,
    TResult? Function(
            int blkheight, String blkhash, List<OwnedOutput> foundOutputs)?
        confirmed,
    TResult? Function(String txid, List<OwnedOutput> outputs)? unconfirmed,
    TResult? Function()? caughtUp,
    TResult? Function(List<OutPoint> outpoints)? spent,
    TResult? Function(String reason)? disconnected,
  }) {
    return disconnected?.call(reason);
  }

  @override
  @optionalTypeArgs
  TResult maybeWhen<TResult extends Object?>({
    TResult Function(int height, String hash)? tip,
    TResult Function(
            int blkheight, String blkhash, List<OwnedOutput> foundOutputs)?
        confirmed,
    TResult Function(String txid, List<OwnedOutput> outputs)? unconfirmed,
    TResult Function()? caughtUp,
    TResult Function(List<OutPoint> outpoints)? spent,
    TResult Function(String reason)? disconnected,
    required TResult orElse(),
  }) {
    if (disconnected != null) {
      return disconnected(reason);
    }
    return orElse();
  }

  @override
  @optionalTypeArgs
  TResult map<TResult extends Object?>({
    required TResult Function(FrigateEventDto_Tip value) tip,
    required TResult Function(FrigateEventDto_Confirmed value) confirmed,
    required TResult Function(FrigateEventDto_Unconfirmed value) unconfirmed,
    required TResult Function(FrigateEventDto_CaughtUp value) caughtUp,
    required TResult Function(FrigateEventDto_Spent value) spent,
    required TResult Function(FrigateEventDto_Disconnected value) disconnected,
  }) {
    return disconnected(this);
  }

  @override
  @optionalTypeArgs
  TResult? mapOrNull<TResult extends Object?>({
    TResult? Function(FrigateEventDto_Tip value)? tip,
    TResult? Function(FrigateEventDto_Confirmed value)? confirmed,
    TResult? Function(FrigateEventDto_Unconfirmed value)? unconfirmed,
    TResult? Function(FrigateEventDto_CaughtUp value)? caughtUp,
    TResult? Function(FrigateEventDto_Spent value)? spent,
    TResult? Function(FrigateEventDto_Disconnected value)? disconnected,
  }) {
    return disconnected?.call(this);
  }

  @override
  @optionalTypeArgs
  TResult maybeMap<TResult extends Object?>({
    TResult Function(FrigateEventDto_Tip value)? tip,
    TResult Function(FrigateEventDto_Confirmed value)? confirmed,
    TResult Function(FrigateEventDto_Unconfirmed value)? unconfirmed,
    TResult Function(FrigateEventDto_CaughtUp value)? caughtUp,
    TResult Function(FrigateEventDto_Spent value)? spent,
    TResult Function(FrigateEventDto_Disconnected value)? disconnected,
    required TResult orElse(),
  }) {
    if (disconnected != null) {
      return disconnected(this);
    }
    return orElse();
  }
}

abstract class FrigateEventDto_Disconnected extends FrigateEventDto {
  const factory FrigateEventDto_Disconnected({required final String reason}) =
      _$FrigateEventDto_DisconnectedImpl;
  const FrigateEventDto_Disconnected._() : super._();

  String get reason;

  /// Create a copy of FrigateEventDto
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  _$$FrigateEventDto_DisconnectedImplCopyWith<
          _$FrigateEventDto_DisconnectedImpl>
      get copyWith => throw _privateConstructorUsedError;
}
