/*
Copyright (c) 2019 Guillaume Desquesnes, Valentin Lemière

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
*/

package json2object.utils.schema;

#if !macro
class DataBuilder {}
#else
import haxe.macro.Expr;
import haxe.macro.Context;
import haxe.macro.Type;
import haxe.macro.TypeTools;
import json2object.utils.schema.JsonType;
import json2object.writer.StringUtils;

using haxe.macro.ExprTools;
using haxe.macro.TypeTools;
using json2object.utils.schema.JsonTypeTools;
using StringTools;

class DataBuilder {

	static var counter:Int = 0;
	static final definitions = new Map<String, JsonType>();

	private static function notNull(type:Type):Type {
		return switch (type) {
			case TAbstract(_.get()=>t, p):
				(t.name == "Null") ? notNull(p[0]) : type;
			case TType(_.get()=>t, p):
				(t.name == "Null") ? notNull(type.follow()) : type;
			default:
				type;
		}
	}

	private static function isNullable(type:Type) {
		if (notNull(type) != type) { return true; }
		return switch (type.followWithAbstracts()) {
			case TAbstract(_.get()=>t,_):
				!t.meta.has(":notNull");
			default:
				true;
		}
	}

	private static function define(name:String, type:JsonType, ?doc:Null<String>=null) {
		if (doc != null) {
			definitions.set(name, JTWithDescr(type, doc));
		}
		else {
			definitions.set(name, type);
		}
	}

	static function anyOf(t1:JsonType, t2:JsonType) {
		return switch [t1, t2] {
			case [JTNull, JTAnyOf(v)], [JTAnyOf(v), JTNull] if (v.indexOf(JTNull) != -1): t2;
			case [JTAnyOf(v1), JTAnyOf(v2)]: JTAnyOf(v1.concat(v2));
			case [JTAnyOf(val), t], [t, JTAnyOf(val)]: JTAnyOf(val.concat([t]));
			default: JTAnyOf([t1, t2]);
		}
	}

	static function makeAbstractSchema(type:Type):JsonType {
		var name = type.toString();
		var doc:Null<String> = null;
		switch (type) {
			case TAbstract(_.get()=>t, p):
				var jt:Null<JsonType> = null;
				var from = (t.from.length == 0) ? [{t:t.type, field:null}] : t.from;
				var possiblesJT:Array<JsonType> = [];
				var i = 0;
				for(fromType in from) {
					try {
						var ft = fromType.t.applyTypeParameters(t.params, p);
						var ft = ft.followWithAbstracts();
						possiblesJT.push(makeSchema(ft));
						if (isNullable(ft)) {
							jt = JTNull;
						}
					}
					catch (_:#if (haxe_ver >= 4) Any #else Dynamic #end) {}
				}
				if (possiblesJT.length == 0) {
					throw "Abstract "+name+ " has no json representation "+ Context.currentPos();
				}
				if (jt == null) {
					jt = possiblesJT.pop();
				}
				while (possiblesJT.length > 0) {
					jt = anyOf(jt, possiblesJT.pop());
				}
				define(name, jt, doc);
				return JTRef(name);
			default:
				throw "Unexpected type "+name;
		}
	}
	static function makeAbstractEnumSchema(type:Type):JsonType {
		var name = type.toString();
		var doc:Null<String> = null;
		var addnull = isNullable(type);
		switch (type.followWithAbstracts()) {
			case TInst(_.get()=>t, _):
				if (t.module != "String") {
					throw "json2object: Unsupported abstract enum type:"+ name + " " + Context.currentPos();
				}
			case TAbstract(_.get()=>t, _):
				if (t.module != "StdTypes" && (t.name != "Int" && t.name != "Bool" && t.name != "Float")) {
					throw "json2object: Unsupported abstract enum type:"+ name + " " + Context.currentPos();
				}
			default: throw "json2object: Unsupported abstract enum type:"+ name + " " + Context.currentPos();
		}
		var values = new Array<Dynamic>();
		var docs = [];

		function handleExpr(expr:TypedExprDef, ?rec:Bool=true) {
			switch (expr) {
				case TConst(TString(s)): values.push(StringUtils.quote(s));
				case TConst(TNull): values.push(null); addnull = false;
				case TConst(TBool(b)): values.push(b);
				case TConst(TFloat(f)): values.push(f);
				case TConst(TInt(i)): values.push(i);
				case TCast(c, _) if (rec): handleExpr(c.expr, false);
				default:
			}
		}
		switch (type) {
			case TAbstract(_.get()=>t, p) :
				doc = t.doc;
				for (field in t.impl.get().statics.get()) {
					if (!field.meta.has(":enum") || !field.meta.has(":impl")) {
						continue;
					}
					if (field.expr() == null) { continue; }
					docs.push(field.doc);
					handleExpr(field.expr().expr);
				}
			default:
		}

		if (values.length == 0) {
			throw 'json2object: Abstract enum ${name} has no supported value';
		}

		var jt = JTEnum(values, docs);
		if (addnull) {
			jt = anyOf(JTNull, jt);
		}
		define(name, jt, doc);
		return JTRef(name);
	}
	static function makeEnumSchema(type:Type):JsonType {
		var name = type.toString();
		var doc:Null<String> = null;

		var simple = [];
		var simpleDoc = [];
		var complexProperties = new Map<String, JsonType>();
		switch (type) {
			case TEnum(_.get()=>t, p):
				for (n in t.names) {
					var construct = t.constructs.get(n);
					var properties = new Map<String, JsonType>();
					var required = [];
					switch (construct.type) {
						case TEnum(_,_):
							simple.push(n);
							simpleDoc.push(construct.doc);
						case TFun(args,_):
							for (a in args) {
								properties.set(a.name, makeSchema(a.t.applyTypeParameters(t.params, p)));
								if (!a.opt) {
									required.push(a.name);
								}
							}
						default:
							continue;
					}
					var jt = JTObject(properties, required);
					complexProperties.set(n, construct.doc != null ? JTWithDescr(jt, construct.doc): jt);
				}
				doc = t.doc;
			default:
		}

		var jt = JTNull;
		if (complexProperties.keys().hasNext()) {
			jt = anyOf(jt, JTObject(complexProperties, [], 1));
		}

		if (simple.length > 0) {
			jt = anyOf(jt, JTEnum(simple.map(StringUtils.quote), simpleDoc));
		}
		define(name, jt, doc);
		return JTRef(name);
	}

	static function makeMapSchema(keyType:Type, valueType:Type):JsonType {
		var name = "Map_" + keyType.toString() + "_" + valueType.toString();
		if (definitions.exists(name)) {
			return JTRef(name);
		}
		var onlyInt = switch (keyType) {
			case TInst(_.get()=>t, _):
				if (t.module == "String") {
					false;
				}
				else {
					throw "json2object: Only map with Int or String key can be transformed to json, got"+keyType.toString() + " " + Context.currentPos();
				}
			case TAbstract(_.get()=>t, _):
				if (t.module == "StdTypes" && t.name == "Int") {
					true;
				}
				else {
					throw "json2object: Only map with Int or String key can be transformed to json, got"+keyType.toString() + " " + Context.currentPos();
				}
			default:
				throw "json2object: Only map with Int or String key can be transformed to json, got"+keyType.toString() + " " + Context.currentPos();
		}
		define(name, anyOf(JTNull, JTMap(onlyInt, makeSchema(valueType))));
		return JTRef(name);
	}
	static function makeObjectSchema(type:Type, name:String):JsonType {
		var properties = new Map<String, JsonType>();
		var required = new Array<String>();

		var fields:Array<ClassField>;

		var tParams:Array<TypeParameter>;
		var params:Array<Type>;

		var doc:Null<String> = null;

		switch (type) {
			case TAnonymous(_.get()=>t):
				fields = t.fields;
				tParams = [];
				params = [];

			case TInst(_.get()=>t, p):
				fields = [];
				var s = t;
				while (s != null)
				{
					fields = fields.concat(s.fields.get());
					s = s.superClass != null ? s.superClass.t.get() : null;
				}

				tParams = t.params;
				params = p;
				doc = t.doc;

			case _: throw "Unexpected type "+name;
		}


		try {
			define(name, null); // Protection against recursive types
			for (field in fields) {
				if (field.meta.has(":jignored")) { continue; }
				switch(field.kind) {
					case FVar(r,w):
						if (r == AccCall && w == AccCall && !field.meta.has(":isVar")) {
							continue;
						}

						if (!field.meta.has(":optional")) {
							required.push(field.name);
						}

						var f_type = field.type.applyTypeParameters(tParams, params);
						properties.set(field.name, JTWithDescr(makeSchema(f_type), field.doc));
					default:
				}
			}

			define(name, anyOf(JTNull, JTObject(properties, required)), doc);
			return JTRef(name);
		}
		catch (e:#if (haxe_ver >= 4) Any #else Dynamic #end) {
			if (definitions.get(name) == null) {
				definitions.remove(name);
			}
			throw e;
		}
	}

	static function makeSchema(type:Type, ?name:String=null) : JsonType {

		if (name == null) {
			name = type.toString();
		}

		if (definitions.exists(name)) {
			return JTRef(name);
		}

		var schema = switch (type) {
			case TInst(_.get()=>t, p):
				switch (t.module) {
					case "String":
						return anyOf(JTNull, JTSimple("string"));
					case "Array" if (p.length == 1 && p[0] != null):
						return anyOf(JTNull, JTArray(makeSchema(p[0])));
					default:
						makeObjectSchema(type, name);
				}
			case TAnonymous(_):
				makeObjectSchema(type, name);
			case TAbstract(_.get()=>t, p):
				if (t.name == "Null") {
					return anyOf(JTNull, makeSchema(p[0]));
				}
				else if (t.module == "StdTypes") {
					switch (t.name) {
						case "Int": return JTSimple("integer");
						case "Float", "Single": JTSimple("number");
						case "Bool": return JTSimple("boolean");
						default: throw "json2object: Schema of "+t.name+" can not be generated " + Context.currentPos();
					}
				}
				else if (t.module == #if (haxe_ver >= 4) "haxe.ds.Map" #else "Map" #end) {
					makeMapSchema(p[0], p[1]);
				}
				else {
					if (t.meta.has(":enum")) {
						makeAbstractEnumSchema(type.applyTypeParameters(t.params, p));
					}
					else {
						makeAbstractSchema(type.applyTypeParameters(t.params, p));
					}
				}
			case TEnum(_.get()=>t,p):
				makeEnumSchema(type.applyTypeParameters(t.params, p));
			case TType(_.get()=>t, p):
				var _tmp = makeSchema(t.type.applyTypeParameters(t.params, p), name);
				if (t.doc != null) {
					define(name, JTWithDescr(definitions.get(name), t.doc));
				}
				_tmp;
			case TLazy(f):
				makeSchema(f());
			default:
				throw "json2object: Json schema can not make a schema for type " + name + " " + Context.currentPos();
		}
		return schema;
	}

	static function format(schema:JsonType) : String {
		var buf = new StringBuf();
		buf.add('{');
		buf.add('"$$schema": "http://json-schema.org/draft-07/schema#",');
		var hasDef = definitions.keys().hasNext();
		if (hasDef) {
			buf.add('"definitions":{');
			var comma = false;
			for (defName in definitions.keys()) {
				if (comma) { buf.add(", "); }
				buf.add('"$defName": ${definitions.get(defName).toString()}');
				comma = true;
			}
			buf.add('},');
		}
		var s = schema.toString();
		buf.add(s.substring(1, s.length - 1));
		buf.add('}');
		return buf.toString();
	}

	static function makeSchemaWriter(c:BaseType, type:Type, base:Type=null) {
		var swriterName = c.name + "_" + (counter++);
		var schema = format(makeSchema(type));
		var schemaWriter = macro class $swriterName {
			public function new () {}
			public #if (haxe_ver >= 4) final #else var #end schema#if (haxe_ver >= 4) #else (default,never) #end:String = $v{schema};
		}
		haxe.macro.Context.defineType(schemaWriter);
		return haxe.macro.Context.getType(swriterName);
	}

	public static function build() {
		switch (Context.getLocalType()) {
			case TInst(c, [type]):
				return makeSchemaWriter(c.get(), type);
			case _:
				Context.fatalError("json2object: Json schema tools must be a class", Context.currentPos());
				return null;
		}
	}
}
#end