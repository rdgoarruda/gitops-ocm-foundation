@beautifulMention

nosso ambiente agora esta funcional:

kind get clusters
gerencia-global
nprod-bu-x
prod-bu-x


---

o que precisamos agora e estruturar um processos gitops, vamos levar em consideracao apenas dois ambientes, nprod e prod ( mas o modelo deve ser extensivel caso queria ter mais de dois ambientes, por exemplo, dv, ho e pr)


porem temos as seguintes particularidades:

1 - Politicas Globais RHACM
    
    politicas que devem ser aplicadas a todos os clusters Openshift (ARO,ROSA,OCI), AKS, EKS
    ter a possibilidade de granularidade de politicas por BU (Business Unit)

2 - GitOps para o que nao for Politica
    
    por exemplo, vou instalar um chart do headlamp por exemplo nos clusters, e cada um deve ter sua particularidades.
    porem aqui e para tudo que nao for governanca, toda a iteracao com o cluster deve ser via codigo, ou seja ate configuracoes de infraestrutura
    devem estar via codigo, versionadas e auditaveis no github

3 - GitOps para terraform (com atlantis) <- mas aqui pode ser o ultimo

    aqui e para a casca do clusters, no trabalho usamos o HCP Terraform, mas vejo que com o atlantis tbem conseguimos seguir o modelo da mesma forma.
    ou seja, apos eu provisionar o meu cluster via terraform, eu preciso de um repositorio no github para controlar o dia2, operacoes e etc referente ao terraform.


---

e aqui mora toda a duvida, cheguei em um ponto de que achei melhor separar esses 3 processos, em processos distitos,
visando que cada um tem sua responsabilidade... porem preciso entender se essa e a forma correta de trabalhar, de acordo com as boas praticas.


e preciso criar toda essa estrutura usando gitops e argocd..

a ideia e que quando o cluster nascer via terraform, ao ser conectado no ACM, todas as politicas globais, ja devem ser aplicadas, sem mais interacoes.

vamos organizar esse pensamento, precisamos subir um rhacm para validar essas particularidades

