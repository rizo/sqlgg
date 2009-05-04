/* 
  Simple SQL parser
*/


%{
  open Printf
  open Sql
  open ListMore
  open Stmt
  open Syntax
  open Operators

  let def_param_name name (id,t) = 
    let name =
    match id with
    | Next | Numbered _ -> name
    | Named x -> x
    in
    (Named name,t)

%}

%token <int> INTEGER
%token <string> IDENT TEXT BLOB
%token <Stmt.param_id> PARAM
%token LPAREN RPAREN COMMA EOF DOT NULL
%token CONFLICT_ALGO
%token SELECT INSERT OR INTO CREATE UPDATE TABLE VALUES WHERE ASTERISK DISTINCT ALL 
       LIMIT ORDER BY DESC ASC EQUAL DELETE FROM DEFAULT OFFSET SET JOIN LIKE_OP
       EXCL TILDE NOT FUNCTION TEST_NULL BETWEEN AND ESCAPE USING COMPOUND_OP AS
       CONCAT_OP JOIN_TYPE1 JOIN_TYPE2 NATURAL REPLACE
%token UNIQUE PRIMARY KEY AUTOINCREMENT ON CONFLICT
%token NUM_BINARY_OP PLUS MINUS
%token T_INTEGER T_BLOB T_TEXT

%type <Syntax.expr> expr

%start <RA.Scheme.t * Stmt.params * Stmt.kind> input

%%

input: statement EOF { $1 } ;

statement: CREATE TABLE name=IDENT LPAREN scheme=column_defs RPAREN
              { let () = Tables.add (name,scheme) in ([],[],Create name) }
         | CREATE TABLE name=IDENT AS select=select_stmt
              { 
                let (s,p) = select in
                Tables.add (name,s);
                ([],p,Create name)
              }
         | select_stmt
              { let (s,p) = $1 in s,p,Select }
         | insert_cmd table=IDENT cols=columns_list? VALUES
              { 
                let s = Tables.get_scheme table in
                let s = match cols with
                  | Some cols -> RA.Scheme.project cols s
                  | None -> s
                in
                let p = Syntax.scheme_as_params s in
                [],p,Insert table
              }
         | update_cmd table=IDENT SET assignments=separated_nonempty_list(COMMA,set_column) w=where?
              { 
                let t = Tables.get table in
                let p2 = get_params_opt [t] w in
                let (cols,exprs) = List.split assignments in
                let _ = RA.Scheme.project cols (snd t) in (* validates columns *)
                let p1 = Syntax.get_params_l [t] exprs in
                [], p1 @ p2, Update table
              }
         | DELETE FROM table=IDENT w=where?
              { 
                let p = get_params_opt [Tables.get table] w in
                [], p, Delete table
              }
              
columns_list: LPAREN cols=separated_nonempty_list(COMMA,IDENT) RPAREN { cols }

select_stmt: select_core list(preceded(COMPOUND_OP,select_core)) o=loption(order) p4=loption(limit)
              { let (s1,p1,tbls) = $1 in
                let (s2,p2) = List.split (List.map (fun (s,p,_) -> s,p) $2) in (* ignore tables in compound statements - they cannot be used in ORDER BY *)
                let p3 = Syntax.get_params_l tbls o in
                List.fold_left RA.Scheme.compound s1 s2,(p1@(List.flatten p2)@p3@p4) }

select_core: SELECT select_type? r=separated_nonempty_list(COMMA,column1)
             FROM t=table_list
             w=where?
              {
                let (tbls,p2) = t in
                let p1 = Syntax.params_of_columns tbls r in
                let p3 = Syntax.get_params_opt tbls w in
                (Syntax.get_scheme r tbls, p1 @ p2 @ p3, tbls)
              }

table_list: source join_source* 
    { 
      let (s,p) = List.split $2 in 
      (fst $1::s, List.flatten (snd $1::p))
    }
join_source: join_op s=source p=loption(join_args) 
    { 
      (* FIXME more tables in scope *)
      (fst s,snd s @ Syntax.get_params_l [fst s] p)
    }
source: IDENT { Tables.get $1,[] }
      | LPAREN s=select_core RPAREN { let (s,p,_) = s in ("",s),p }
join_op: COMMA | NATURAL? JOIN_TYPE1? JOIN_TYPE2? JOIN { } ;
join_args: ON e=expr { [e] }
         | USING LPAREN l=separated_nonempty_list(COMMA,IDENT) RPAREN { List.map (fun name -> `Column (name,None)) l }

insert_cmd: INSERT OR CONFLICT_ALGO INTO | INSERT INTO | REPLACE INTO { }

update_cmd: UPDATE {}
          | UPDATE OR CONFLICT_ALGO {} ;

select_type: DISTINCT | ALL { }

int_or_param: INTEGER { [] }
            | PARAM { [($1,Some Sql.Type.Int)] }

limit: LIMIT p=int_or_param { p }
     | LIMIT p1=int_or_param COMMA p2=int_or_param { p1 @ p2 }
     | LIMIT p1=int_or_param OFFSET p2=int_or_param { p1 @ p2 }

order: ORDER BY l=separated_nonempty_list(COMMA,terminated(expr,order_type?)) { l }
order_type: DESC | ASC { }

where: WHERE e=expr { e }

column1:
       | IDENT DOT ASTERISK { Syntax.AllOf $1 }
       | ASTERISK { Syntax.All }
       | expr maybe_as { let e = $1 in Syntax.Expr (e,$2) }

maybe_as: option(AS) name=IDENT { Some name }
        | { None }

column_defs: separated_nonempty_list(COMMA,column_def1) { $1 }
column_def1: IDENT sql_type column_def_extra* { RA.attr $1 $2 } ;
column_def_extra: PRIMARY KEY { Some Constraint.PrimaryKey }
                | NOT NULL { Some Constraint.NotNull }
                | UNIQUE { Some Constraint.Unique }
                | AUTOINCREMENT { Some Constraint.Autoincrement }
                | ON CONFLICT CONFLICT_ALGO { None } ;
                | DEFAULT INTEGER { None }

set_column: name=IDENT EQUAL e=expr { name,e }

(* expr: expr1 { $1 >> Syntax.expr_to_string >> prerr_endline; $1 } *)

expr:
      expr binary_op expr { `Sub [$1;$3] }
(*     | expr NOT? LIKE_OP expr (*escape?*) { Sub [$1;$4] } *)
(*     | unary_op expr { $2 } *)
    | LPAREN expr RPAREN { $2 }
    | IDENT { `Column ($1,None) }
    | t=IDENT DOT c=IDENT
    | IDENT DOT t=IDENT DOT c=IDENT { `Column (c,Some t) }
    | INTEGER { `Value Sql.Type.Int }
    | TEXT { `Value Sql.Type.Text }
    | BLOB { `Value Sql.Type.Blob }
    | PARAM { `Param ($1,None) }
    | FUNCTION LPAREN func_params RPAREN { `Sub $3 }
    | expr TEST_NULL { $1 }
    | expr BETWEEN expr AND expr { `Sub [$1;$3;$5] }

expr_list: separated_nonempty_list(COMMA,expr) { $1 }
func_params: expr_list { $1 }
           | ASTERISK { [] } ;
escape: ESCAPE expr { $2 }
binary_op: EQUAL | PLUS | MINUS | ASTERISK | AND | OR | NUM_BINARY_OP | CONCAT_OP { } 

unary_op: EXCL { }
        | PLUS { }
        | MINUS { }
        | TILDE { }
        | NOT { } ;

sql_type: T_INTEGER  { Type.Int }
        | T_BLOB { Type.Blob }
        | T_TEXT { Type.Text } ;

